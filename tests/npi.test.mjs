import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import test from "node:test"
import vm from "node:vm"

const source = readFileSync(new URL("../NPI.js", import.meta.url), "utf8")
const context = vm.createContext({
  Array,
  Error,
  JSON,
  Math,
  Number,
  String,
  encodeURIComponent,
  isFinite
})
vm.runInContext(source, context)

const individualFixture = JSON.stringify({
  result_count: 1,
  results: [
    {
      number: "1942262431",
      enumeration_type: "NPI-1",
      basic: {
        first_name: "JOHN",
        middle_name: "ALAN",
        last_name: "AALBERS",
        credential: "M.D.",
        name_suffix: "--",
        status: "A",
        enumeration_date: "2006-04-03"
      },
      taxonomies: [
        { code: "207R00000X", desc: "Internal Medicine", primary: false, license: "X1" },
        { code: "2084N0400X", desc: "Psychiatry & Neurology, Neurology", primary: true, license: "G26935", state: "CA" }
      ],
      addresses: [
        {
          address_purpose: "MAILING",
          address_1: "PO BOX 1",
          city: "SAN DIEGO",
          state: "CA",
          postal_code: "921032116",
          telephone_number: "619-299-8500"
        },
        {
          address_purpose: "LOCATION",
          address_1: "4060 4TH AVE",
          address_2: "SUITE 700",
          city: "SAN DIEGO",
          state: "CA",
          postal_code: "921032116",
          telephone_number: "6192998500"
        }
      ]
    }
  ]
})

const organizationFixture = JSON.stringify({
  result_count: 1,
  results: [
    {
      number: "1447750123",
      enumeration_type: "NPI-2",
      basic: { organization_name: "MAYO CLINIC", status: "A", enumeration_date: "2014-02-05" },
      taxonomies: [{ code: "282N00000X", desc: "General Acute Care Hospital", primary: true, license: "" }],
      addresses: [
        {
          address_purpose: "LOCATION",
          address_1: "200 1ST ST SW",
          city: "ROCHESTER",
          state: "MN",
          postal_code: "559050001",
          telephone_number: "5072842511"
        }
      ]
    }
  ]
})

test("buildSearchUrl sends a bare NPI as a number lookup", () => {
  const url = context.buildSearchUrl("1942262431", "individual", "CA", 8)
  assert.match(url, /number=1942262431/)
  assert.doesNotMatch(url, /last_name/)
  // An NPI names exactly one record, so the other filters must not narrow it.
  assert.doesNotMatch(url, /enumeration_type/)
  assert.doesNotMatch(url, /state=/)
})

test("buildSearchUrl accepts an NPI typed with spaces or dashes", () => {
  assert.match(context.buildSearchUrl("1942 262 431", "individual", "", 8), /number=1942262431/)
  assert.match(context.buildSearchUrl("1942-262-431", "individual", "", 8), /number=1942262431/)
})

test("a nine-digit number is a name search, not an NPI lookup", () => {
  const url = context.buildSearchUrl("194226243", "individual", "", 8)
  assert.doesNotMatch(url, /number=/)
  assert.match(url, /last_name=194226243/)
})

test("buildSearchUrl splits a full name into first and last", () => {
  const url = context.buildSearchUrl("john aalbers", "individual", "", 8)
  assert.match(url, /first_name=john\*/)
  assert.match(url, /last_name=aalbers\*/)
  assert.match(url, /enumeration_type=NPI-1/)
})

test("a single word is treated as a surname", () => {
  const url = context.buildSearchUrl("aalbers", "individual", "", 8)
  assert.match(url, /last_name=aalbers\*/)
  assert.doesNotMatch(url, /first_name/)
})

// Directories and claim systems print "Last, First".
test("a comma reverses the name order", () => {
  const url = context.buildSearchUrl("Aalbers, John", "individual", "", 8)
  assert.match(url, /last_name=Aalbers\*/)
  assert.match(url, /first_name=John\*/)
})

test("a middle name stays with the surname rather than being dropped", () => {
  const url = context.buildSearchUrl("john alan aalbers", "individual", "", 8)
  assert.match(url, /first_name=john\*/)
  assert.match(url, /last_name=alan%20aalbers\*/)
})

test("organization mode searches the organization name field", () => {
  const url = context.buildSearchUrl("mayo clinic", "organization", "MN", 8)
  assert.match(url, /organization_name=mayo%20clinic\*/)
  assert.match(url, /enumeration_type=NPI-2/)
  assert.match(url, /state=MN/)
  assert.doesNotMatch(url, /last_name/)
})

test("an unknown mode falls back to an individual search", () => {
  assert.match(context.buildSearchUrl("aalbers", "nonsense", "", 8), /enumeration_type=NPI-1/)
})

// NPPES rejects a wildcard with fewer than two leading characters, so a
// one-letter term has to go out unstarred.
test("wildcard only applies from two characters up", () => {
  assert.equal(context.wildcard("a"), "a")
  assert.equal(context.wildcard("ab"), "ab*")
  assert.equal(context.wildcard("ab*"), "ab*")
  assert.equal(context.wildcard(""), "")
})

test("normalizeState keeps two letters and discards anything else", () => {
  assert.equal(context.normalizeState("ca"), "CA")
  assert.equal(context.normalizeState(" mn "), "MN")
  assert.equal(context.normalizeState("California"), "")
  assert.equal(context.normalizeState("C"), "")
})

test("buildSearchUrl refuses a blank query", () => {
  assert.equal(context.buildSearchUrl("  ", "individual", "CA", 8), "")
})

test("clampResultLimit holds the panel between five and twelve rows", () => {
  assert.equal(context.clampResultLimit(1), 5)
  assert.equal(context.clampResultLimit(500), 12)
  assert.equal(context.clampResultLimit("not a number"), 8)
})

test("parseSearchResponse reads an individual record", () => {
  const parsed = context.parseSearchResponse(individualFixture)
  assert.equal(parsed.totalCount, 1)
  const provider = parsed.providers[0]
  assert.equal(provider.npi, "1942262431")
  assert.equal(provider.name, "John Alan Aalbers")
  assert.equal(provider.credential, "M.D.")
  assert.equal(provider.typeLabel, "Individual")
  assert.equal(provider.active, true)
  assert.equal(provider.url, "https://npiregistry.cms.hhs.gov/provider-view/1942262431")
})

// The first taxonomy in the array is not necessarily the primary one.
test("parseSearchResponse picks the primary taxonomy, not the first", () => {
  const provider = context.parseSearchResponse(individualFixture).providers[0]
  assert.equal(provider.taxonomy, "Psychiatry & Neurology, Neurology")
  assert.equal(provider.taxonomyCode, "2084N0400X")
  assert.equal(provider.license, "G26935")
})

// The practice location is what a caller wants, even when the mailing address
// is listed first.
test("parseSearchResponse prefers the practice location over the mailing address", () => {
  const provider = context.parseSearchResponse(individualFixture).providers[0]
  assert.equal(provider.street, "4060 4th Ave, Suite 700")
  assert.equal(provider.location, "San Diego, CA 92103-2116")
})

test("parseSearchResponse rebuilds a bare telephone number", () => {
  assert.equal(context.parseSearchResponse(individualFixture).providers[0].phone, "619-299-8500")
})

test("parseSearchResponse reads an organization record", () => {
  const provider = context.parseSearchResponse(organizationFixture).providers[0]
  assert.equal(provider.name, "Mayo Clinic")
  assert.equal(provider.typeLabel, "Organization")
  assert.equal(provider.organization, true)
  assert.equal(provider.location, "Rochester, MN 55905-0001")
  assert.equal(provider.credential, "")
})

// NPPES answers a rejected query with 200 OK and an Errors array, so the
// failure has to be read out of the body.
test("parseSearchResponse surfaces the Errors array", () => {
  const parsed = context.parseSearchResponse(
    '{"Errors":[{"description":"NPI must be 10 digits","field":"number","number":"06"}]}'
  )
  assert.equal(parsed.errors.length, 1)
  assert.equal(parsed.errors[0], "NPI must be 10 digits")
  assert.equal(parsed.providers.length, 0)
})

test("parseSearchResponse treats no results as zero matches", () => {
  const parsed = context.parseSearchResponse('{"result_count":0,"results":[]}')
  assert.equal(parsed.totalCount, 0)
  assert.equal(parsed.providers.length, 0)
  assert.equal(parsed.errors.length, 0)
})

test("parseSearchResponse rejects a body that is not an object", () => {
  assert.throws(() => context.parseSearchResponse("not json"))
})

test("a deactivated enumeration is not reported as active", () => {
  const parsed = context.parseSearchResponse(
    '{"result_count":1,"results":[{"number":"1111111111","enumeration_type":"NPI-1","basic":{"last_name":"GONE","status":"I"},"taxonomies":[],"addresses":[]}]}'
  )
  const provider = parsed.providers[0]
  assert.equal(provider.active, false)
  assert.equal(provider.location, "No address on file")
  assert.equal(provider.taxonomy, "")
})

// "--" is how NPPES spells "no value" and must never be printed.
test("a placeholder credential is dropped", () => {
  const parsed = context.parseSearchResponse(
    '{"result_count":1,"results":[{"number":"1111111111","enumeration_type":"NPI-1","basic":{"last_name":"X","credential":"--"},"taxonomies":[],"addresses":[]}]}'
  )
  assert.equal(parsed.providers[0].credential, "")
})

test("formatPostalCode expands a nine-digit ZIP", () => {
  assert.equal(context.formatPostalCode("921032116"), "92103-2116")
  assert.equal(context.formatPostalCode("92103"), "92103")
  assert.equal(context.formatPostalCode(""), "")
})

test("formatPhone normalises both shapes NPPES returns", () => {
  assert.equal(context.formatPhone("6192998500"), "619-299-8500")
  assert.equal(context.formatPhone("619-299-8500"), "619-299-8500")
  assert.equal(context.formatPhone("16192998500"), "619-299-8500")
  assert.equal(context.formatPhone(""), "")
})

test("formatCount groups thousands", () => {
  assert.equal(context.formatCount(1234), "1,234")
  assert.equal(context.formatCount("nope"), "0")
})

// A search for "Smith" can answer with a record named Audette, because NPPES
// matches former names too. The other name is carried through so the result
// does not read as a mismatch.
test("parseSearchResponse carries a former name through", () => {
  const parsed = context.parseSearchResponse(
    '{"result_count":1,"results":[{"number":"1215266028","enumeration_type":"NPI-1","basic":{"first_name":"JUDY","last_name":"AUDETTE","status":"A"},"taxonomies":[],"addresses":[],"other_names":[{"first_name":"JUDY","middle_name":"ANN","last_name":"SMITH","type":"Former Name"}]}]}'
  )
  assert.equal(parsed.providers[0].otherName, "Former Name: Judy Ann Smith")
})

test("a record with no other names reports none", () => {
  assert.equal(context.parseSearchResponse(individualFixture).providers[0].otherName, "")
})
