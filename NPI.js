var SEARCH_BASE = "https://npiregistry.cms.hhs.gov/api/"
var API_VERSION = "2.1"
var RECORD_BASE = "https://npiregistry.cms.hhs.gov/provider-view/"
var REGISTRY_URL = "https://npiregistry.cms.hhs.gov/search"

// NPPES splits its registry by enumeration type: NPI-1 is an individual
// clinician, NPI-2 an organization. The two are searched through different
// name fields and cannot be covered by one request - a query carrying both
// last_name and organization_name is ANDed and matches nothing - so the
// widget asks for one or the other rather than pretending to search both.
var TYPE_FILTERS = {
  individual: "NPI-1",
  organization: "NPI-2"
}

function clampResultLimit(value) {
  var parsed = Number(value)
  if (!isFinite(parsed)) return 8
  return Math.max(5, Math.min(12, Math.round(parsed)))
}

function typeKey(value) {
  var normalized = String(value || "").toLowerCase()
  return TYPE_FILTERS.hasOwnProperty(normalized) ? normalized : "individual"
}

// An NPI is ten digits. Punctuation and spacing are stripped first so a
// number pasted as "1942 262 431" still resolves to a direct lookup.
function digitsOnly(value) {
  return String(value || "").replace(/[^0-9]/g, "")
}

function looksLikeNpi(query) {
  var trimmed = String(query || "").trim()
  return /^[0-9\s-]+$/.test(trimmed) && digitsOnly(trimmed).length === 10
}

// Two letters, or nothing. NPPES rejects a state that arrives without another
// criterion, so the caller must never send this on its own.
function normalizeState(value) {
  var normalized = String(value || "").trim().toUpperCase()
  return /^[A-Z]{2}$/.test(normalized) ? normalized : ""
}

// "Aalbers, John" and "John Aalbers" both name the same clinician. The comma
// form is what directories and claim systems print, so it is read as
// last-first; anything else is read as first-then-last, with the final word
// taken as the surname.
function splitName(query) {
  var normalized = String(query || "").replace(/\s+/g, " ").trim()
  if (normalized === "") return { firstName: "", lastName: "" }

  if (normalized.indexOf(",") >= 0) {
    var halves = normalized.split(",")
    return {
      lastName: halves[0].trim(),
      firstName: (halves[1] || "").trim()
    }
  }

  var words = normalized.split(" ")
  if (words.length === 1) return { firstName: "", lastName: words[0] }
  return {
    firstName: words[0],
    lastName: words.slice(1).join(" ")
  }
}

// NPPES matches names exactly unless asked for a prefix, and it rejects a
// wildcard with fewer than two leading characters. Anything long enough gets
// the star so a partial name still finds the provider.
function wildcard(value) {
  var normalized = String(value || "").trim()
  if (normalized === "" || normalized.indexOf("*") >= 0) return normalized
  return normalized.length >= 2 ? normalized + "*" : normalized
}

function encodeParameters(parameters) {
  return parameters.filter(function(parameter) {
    return String(parameter[1]) !== ""
  }).map(function(parameter) {
    return encodeURIComponent(parameter[0]) + "=" + encodeURIComponent(parameter[1])
  }).join("&")
}

function buildSearchUrl(query, type, state, resultLimit) {
  var normalized = String(query || "").trim()
  if (normalized === "") return ""

  var parameters = [
    ["version", API_VERSION],
    ["limit", String(clampResultLimit(resultLimit))]
  ]

  // A number search is unambiguous, so it ignores every other filter - an NPI
  // identifies exactly one record whatever its type or state.
  if (looksLikeNpi(normalized)) {
    parameters.push(["number", digitsOnly(normalized)])
    return SEARCH_BASE + "?" + encodeParameters(parameters)
  }

  var key = typeKey(type)
  parameters.push(["enumeration_type", TYPE_FILTERS[key]])
  parameters.push(["state", normalizeState(state)])

  if (key === "organization") {
    parameters.push(["organization_name", wildcard(normalized)])
  } else {
    var name = splitName(normalized)
    parameters.push(["first_name", wildcard(name.firstName)])
    parameters.push(["last_name", wildcard(name.lastName)])
  }

  return SEARCH_BASE + "?" + encodeParameters(parameters)
}

function formatPostalCode(value) {
  var digits = digitsOnly(value)
  if (digits.length === 9) return digits.slice(0, 5) + "-" + digits.slice(5)
  return digits.length === 0 ? "" : digits
}

// NPPES returns telephone numbers both dashed and bare, so they are rebuilt
// from the digits rather than passed through as they arrive.
function formatPhone(value) {
  var digits = digitsOnly(value)
  if (digits.length === 11 && digits.charAt(0) === "1") digits = digits.slice(1)
  if (digits.length !== 10) return String(value || "").trim()
  return digits.slice(0, 3) + "-" + digits.slice(3, 6) + "-" + digits.slice(6)
}

function titleCase(value) {
  return String(value || "").toLowerCase().replace(/\b[a-z]/g, function(letter) {
    return letter.toUpperCase()
  })
}

function providerName(record) {
  var basic = (record && record.basic) || {}
  if (String(record && record.enumeration_type) === "NPI-2")
    return titleCase(basic.organization_name) || "Unnamed organization"

  var parts = [basic.first_name, basic.middle_name, basic.last_name].filter(function(part) {
    return String(part || "").trim() !== ""
  })
  var name = titleCase(parts.join(" ")).trim()
  return name === "" ? "Unnamed provider" : name
}

// A suffix of "--" is how NPPES spells "none", and it must not be printed.
function credentialOf(record) {
  var credential = String(((record && record.basic) || {}).credential || "").trim()
  return credential === "--" ? "" : credential
}

function primaryTaxonomy(record) {
  var taxonomies = (record && record.taxonomies) || []
  for (var index = 0; index < taxonomies.length; index++) {
    if (taxonomies[index] && taxonomies[index].primary) return taxonomies[index]
  }
  return taxonomies.length > 0 ? taxonomies[0] : null
}

// The practice location is what a caller wants; the mailing address is only a
// fallback for records that carry nothing else.
function primaryAddress(record) {
  var addresses = (record && record.addresses) || []
  var purposes = ["LOCATION", "PRIMARY", "MAILING"]
  for (var index = 0; index < purposes.length; index++) {
    for (var inner = 0; inner < addresses.length; inner++) {
      if (addresses[inner] && String(addresses[inner].address_purpose) === purposes[index])
        return addresses[inner]
    }
  }
  return addresses.length > 0 ? addresses[0] : null
}

function locationLabel(address) {
  if (!address) return "No address on file"
  var city = titleCase(address.city)
  var state = String(address.state || "").trim().toUpperCase()
  var postal = formatPostalCode(address.postal_code)
  var parts = [city, state].filter(function(part) {
    return part !== ""
  })
  var label = parts.join(", ")
  if (postal !== "") label = label === "" ? postal : label + " " + postal
  return label === "" ? "No address on file" : label
}

function streetLabel(address) {
  if (!address) return ""
  var street = [address.address_1, address.address_2].filter(function(part) {
    return String(part || "").trim() !== ""
  }).join(", ")
  return titleCase(street)
}

// NPPES matches a search against former and other names as well as the
// current one, so a search for "Smith" can answer with a record named
// Audette. Carrying the other name through is what makes that result legible
// rather than looking like a mismatch.
function otherNameLabel(record) {
  var others = (record && record.other_names) || []
  for (var index = 0; index < others.length; index++) {
    var entry = others[index]
    if (!entry) continue
    var parts = [entry.first_name, entry.middle_name, entry.last_name].filter(function(part) {
      return String(part || "").trim() !== ""
    })
    if (parts.length === 0) continue
    var kind = String(entry.type || "").trim()
    return (kind === "" ? "Also" : kind) + ": " + titleCase(parts.join(" "))
  }
  return ""
}

function parseProvider(record) {
  var basic = (record && record.basic) || {}
  var taxonomy = primaryTaxonomy(record)
  var address = primaryAddress(record)
  var npi = String((record && record.number) || "")
  var isOrganization = String(record && record.enumeration_type) === "NPI-2"

  return {
    npi: npi,
    name: providerName(record),
    credential: credentialOf(record),
    organization: isOrganization,
    typeLabel: isOrganization ? "Organization" : "Individual",
    taxonomy: taxonomy ? String(taxonomy.desc || "").trim() : "",
    taxonomyCode: taxonomy ? String(taxonomy.code || "").trim() : "",
    license: taxonomy ? String(taxonomy.license || "").trim() : "",
    location: locationLabel(address),
    street: streetLabel(address),
    phone: address ? formatPhone(address.telephone_number) : "",
    // NPPES marks an active enumeration "A"; anything else has been
    // deactivated and should not be trusted on a new claim.
    active: String(basic.status || "").toUpperCase() === "A",
    enumerated: String(basic.enumeration_date || "").trim(),
    otherName: otherNameLabel(record),
    url: npi === "" ? "" : RECORD_BASE + encodeURIComponent(npi)
  }
}

// NPPES reports a rejected query as an Errors array alongside a 200 status,
// so the error path has to be read out of the body rather than the transport.
function parseSearchResponse(raw) {
  var payload = JSON.parse(String(raw || ""))
  if (!payload || typeof payload !== "object") throw new Error("unexpected response shape")

  var errors = (payload.Errors || []).map(function(error) {
    return String((error && error.description) || "").trim()
  }).filter(function(description) {
    return description !== ""
  })

  var results = Array.isArray(payload.results) ? payload.results : []
  return {
    errors: errors,
    totalCount: Number(payload.result_count) || 0,
    providers: results.filter(function(record) {
      return record && record.number
    }).map(parseProvider)
  }
}

function formatCount(value) {
  var digits = String(Math.max(0, Math.round(Number(value) || 0)))
  return digits.replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}
