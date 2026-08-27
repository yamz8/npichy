import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "NPI.js" as NPI

Panel {
  id: root

  moduleName: "yamz8.npichy"
  ipcTarget: "yamz8.npichy"
  // The panel's own IpcHandler below replaces the one Panel installs, so that
  // lookup() and copy() can join the stock open/close/toggle methods on the
  // same target instead of contending with them for it.
  manageIpc: false

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  // An account-search mark (U+F0B73) from the Material Design Icons range,
  // drawn from Omarchy's configured Nerd Font so it stays monochrome and
  // theme-tinted. No other installed widget uses it - pubmedchy takes the
  // book and icd10chy the tag.
  readonly property string npiIcon: "󰭳"
  // Hard ceiling on how much of an NPPES response the shell will ever hold.
  // Twelve records run to a few tens of kilobytes, so 2 MiB is headroom that
  // still stops a hostile or hijacked endpoint from growing the shell process
  // without bound. Enforced in the fetch pipeline and re-checked here before
  // anything is parsed.
  readonly property int maxResponseBytes: 2 * 1024 * 1024
  readonly property int resultLimit: NPI.clampResultLimit(setting("resultLimit", 8))
  // Records carry anything from a bare name to a full practice address, so
  // rows size themselves and the list takes what they need up to this
  // ceiling.
  readonly property int maxResultsHeight: Style.space(430)
  readonly property int resultsHeight: results.length > 0 ? Math.min(resultList.contentHeight, root.maxResultsHeight) : 0
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property string query: ""
  property string stateFilter: ""
  property string searchType: "individual"
  property string resultsQuery: ""
  property string lastSignature: ""
  property var results: []
  property int totalCount: 0
  property int selectedIndex: 0
  property bool searching: false
  property bool aborting: false
  property string errorText: ""
  property string copiedNpi: ""

  function searchSignature() {
    return root.query.trim() + "\n" + root.searchType + "\n" + NPI.normalizeState(root.stateFilter)
  }

  function typeLabel() {
    return root.searchType === "organization" ? "Organizations" : "Individuals"
  }

  function scopeLabel() {
    var state = NPI.normalizeState(root.stateFilter)
    if (NPI.looksLikeNpi(root.query))
      return "NPI number";

    return root.typeLabel() + (state === "" ? "  ·  all states" : "  ·  " + state)
  }

  function restoreDefaults() {
    root.searchType = root.setting("defaultType", "individual") === "organization" ? "organization" : "individual"
    root.stateFilter = NPI.normalizeState(root.setting("defaultState", ""))
  }

  function stopRequests() {
    if (searchProcess.running)
      searchProcess.running = false;
  }

  function clearSensitiveState() {
    root.aborting = true;
    root.stopRequests();
    root.query = "";
    root.resultsQuery = "";
    root.lastSignature = "";
    root.results = [];
    root.totalCount = 0;
    root.selectedIndex = 0;
    root.searching = false;
    root.errorText = "";
    root.copiedNpi = "";
  }

  function failWith(message) {
    root.searching = false;
    root.results = [];
    root.totalCount = 0;
    root.errorText = message;
  }

  // curl is capped twice over. --max-filesize stops the transfer at the limit
  // even when the endpoint declares no Content-Length, and the head -c stage
  // holds the same bound on curl builds that only honour a declared length.
  // pipefail keeps curl's own status as the pipeline status, so timeouts and
  // transport failures still reach onExited unchanged. The URL is passed as a
  // positional argument and after --, never spliced into the script text.
  function fetchCommand(url) {
    return ["bash", "-c", "set -o pipefail; " + "curl -fsS --max-time 12 --connect-timeout 5 " + "--max-filesize " + root.maxResponseBytes + " " + "--user-agent npichy/1.0 -- \"$1\" " + "| head -c " + root.maxResponseBytes, "npichy", url];
  }

  // A response that reaches the cap was truncated mid-flight and cannot be
  // valid JSON, so it is refused before any parser sees it.
  function refuseOversized(raw) {
    if (raw.length < root.maxResponseBytes)
      return false;

    root.failWith("The registry returned an oversized response — narrow the search and retry");
    return true;
  }

  function runSearch() {
    var url = NPI.buildSearchUrl(root.query, root.searchType, root.stateFilter, root.resultLimit);
    if (!url) {
      searchField.forceActiveFocus();
      return;
    }
    if (root.searching)
      return;

    root.aborting = false;
    root.searching = true;
    root.errorText = "";
    root.copiedNpi = "";
    root.results = [];
    root.totalCount = 0;
    root.selectedIndex = 0;
    root.resultsQuery = root.query.trim();
    root.lastSignature = root.searchSignature();
    searchProcess.command = root.fetchCommand(url);
    searchProcess.running = true;
  }

  function applySearch(raw) {
    if (!root.opened || root.aborting)
      return;

    if (root.refuseOversized(raw))
      return;

    var parsed;
    try {
      parsed = NPI.parseSearchResponse(raw);
    } catch (error) {
      root.failWith("The registry returned an unreadable response — retry shortly");
      return;
    }

    // NPPES reports a rejected query as an Errors array under a 200 status,
    // so a refusal has to be read out of the body and shown as one.
    if (parsed.errors.length > 0) {
      root.failWith(parsed.errors.join("  ·  "));
      return;
    }

    root.totalCount = parsed.totalCount;
    root.results = parsed.providers;
    root.selectedIndex = 0;
    root.searching = false;
    root.errorText = parsed.providers.length === 0 ? "No provider matched — try fewer letters, a different state, or the other record type" : "";
  }

  function networkError(exitCode) {
    // 28 is curl's timeout. 63 is --max-filesize, 23 is curl failing to write
    // once head -c has closed the pipe, and 141 is that same stage seen as
    // SIGPIPE — all three mean the response outgrew the cap.
    if (exitCode === 28)
      return "The registry timed out — check the connection and retry";

    if (exitCode === 63 || exitCode === 23 || exitCode === 141)
      return "The registry returned an oversized response — narrow the search and retry";

    return "The registry is unavailable — check the connection and retry";
  }

  function refreshAfterFilterChange() {
    if (root.resultsQuery !== "" && !root.searching)
      root.runSearch();
  }

  function moveSelection(delta) {
    if (root.results.length === 0)
      return;

    root.selectedIndex = Math.max(0, Math.min(root.results.length - 1, root.selectedIndex + delta));
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
  }

  function selectedProvider() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.results.length)
      return null;

    return root.results[root.selectedIndex];
  }

  // Copying is the primary action: the NPI is what gets pasted into a claim,
  // a referral, or a directory record. The panel stays open so the next
  // provider is one keystroke away. The number goes after -- as its own
  // argument, never through a shell.
  function copySelected() {
    var entry = root.selectedProvider();
    if (!entry || entry.npi === "")
      return;

    Quickshell.execDetached(["wl-copy", "--", entry.npi]);
    root.copiedNpi = entry.npi;
  }

  function openSelected() {
    var entry = root.selectedProvider();
    if (!entry || entry.url === "")
      return;

    Quickshell.execDetached(["omarchy-launch-browser", entry.url]);
    root.close();
  }

  function openRegistry() {
    Quickshell.execDetached(["omarchy-launch-browser", NPI.REGISTRY_URL]);
    root.close();
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.close();
      return true;
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1);
      return true;
    }
    if (event.key === Qt.Key_Down) {
      root.moveSelection(1);
      return true;
    }
    if (event.key === Qt.Key_Up) {
      root.moveSelection(-1);
      return true;
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.searching || root.results.length === 0 || root.lastSignature !== root.searchSignature())
        root.runSearch();
      else if (event.modifiers & Qt.ControlModifier)
        root.openSelected();
      else
        root.copySelected();
      return true;
    }
    return false;
  }

  onOpenedChanged: {
    root.clearSensitiveState();
    root.restoreDefaults();
    if (root.opened)
      Qt.callLater(function () {
        searchField.forceActiveFocus();
      });
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void {
      root.open();
    }
    function close(): void {
      root.close();
    }
    function show(): void {
      root.open();
    }
    function hide(): void {
      root.close();
    }
    function toggle(): void {
      root.toggle();
    }
    // Look a provider up from a keybinding or a script:
    //   omarchy-shell yamz8.npichy lookup "john aalbers"
    // The text is written to the field rather than to root.query, because the
    // field owns the query once it has been typed in and would otherwise keep
    // showing the previous term.
    // The optional second argument picks the record type, so a keybinding can
    // go straight to organizations:
    //   omarchy-shell yamz8.npichy lookup "mayo clinic" organization
    function lookup(query: string, type: string): string {
      var normalized = String(query || "").trim();
      if (normalized === "")
        return "empty query";

      root.open();
      if (String(type || "").trim() !== "")
        root.searchType = String(type).toLowerCase() === "organization" ? "organization" : "individual";

      searchField.text = normalized;
      Qt.callLater(function () {
        root.runSearch();
      });
      return "ok";
    }
    // Copy whatever is selected, so a keybinding can pair with lookup to put
    // the closest NPI on the clipboard without touching the panel.
    function copy(): string {
      var entry = root.selectedProvider();
      if (!entry)
        return "no selection";

      root.copySelected();
      return entry.npi;
    }
  }

  Process {
    id: searchProcess

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySearch(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (root.aborting) {
        root.aborting = false;
        return;
      }
      if (exitCode !== 0 && root.opened)
        root.failWith(root.networkError(exitCode));
    }
  }

  BarIconButton {
    id: barButton

    anchors.fill: parent
    bar: root.bar
    text: root.npiIcon
    tooltipText: "npichy · look up a provider in the NPI registry"

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.RightButton)
        root.openRegistry();
      else
        root.toggle();
    }
  }

  KeyboardPanel {
    id: popout

    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: popout.fittedContentWidth(Style.space(720))
    contentHeight: popout.fittedContentHeight(content.implicitHeight, Style.space(820))

    Column {
      id: content

      width: parent.width
      spacing: Style.space(12)

      PanelHero {
        width: parent.width
        title: "npichy"
        meta: "NPPES national provider identifier registry"
        detail: "LIVE"
        foreground: root.foreground
        fontFamily: root.fontFamily

        iconComponent: Component {
          Text {
            text: root.npiIcon
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }

        trailingControl: Component {
          Button {
            text: "Open registry"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.openRegistry()
          }
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      Column {
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader {
          width: parent.width
          text: "FIND A PROVIDER"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          width: parent.width
          spacing: Style.spacing.sm

          TextField {
            id: searchField

            width: parent.width - stateField.width - searchButton.width - parent.spacing * 2
            foreground: root.foreground
            placeholderText: "Aalbers, Mayo Clinic, 1942262431…"
            text: root.query
            onTextChanged: {
              root.query = text;
              root.copiedNpi = "";
            }
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function (event) {
              if (root.handleKey(event))
                event.accepted = true;
            }
          }

          TextField {
            id: stateField

            width: Style.space(72)
            foreground: root.foreground
            placeholderText: "State"
            maximumLength: 2
            text: root.stateFilter
            // NPPES refuses a state that arrives without another criterion,
            // and only ever matches two-letter codes, so the field is held to
            // that shape as it is typed.
            onTextChanged: {
              var normalized = text.toUpperCase().replace(/[^A-Z]/g, "");
              if (normalized !== text)
                text = normalized;

              root.stateFilter = normalized;
            }
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function (event) {
              if (root.handleKey(event))
                event.accepted = true;
            }
          }

          Button {
            id: searchButton

            width: Math.max(Style.space(88), implicitWidth)
            text: root.searching ? "Looking…" : "Look up"
            bordered: true
            selected: true
            enabled: root.query.trim() !== "" && !root.searching
            opacity: enabled ? 1 : 0.45
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.runSearch()
          }
        }

        Text {
          width: parent.width
          text: root.copiedNpi !== "" ? "Copied NPI " + root.copiedNpi + " to the clipboard" : root.results.length > 0 && root.lastSignature !== root.searchSignature() ? "Query changed — press Enter or Look up to refresh these results" : "A name, an organization, or a ten-digit NPI"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: root.copiedNpi !== "" ? 0.8 : root.results.length > 0 && root.lastSignature !== root.searchSignature() ? 0.72 : 0.42
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(typeHeader.implicitHeight, typeGroup.implicitHeight)

        PanelSectionHeader {
          id: typeHeader

          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "RECORD TYPE"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        ButtonGroup {
          id: typeGroup

          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          options: [
            {
              value: "individual",
              label: "Individual",
              tooltip: "NPI-1 — a clinician, searched by first and last name"
            },
            {
              value: "organization",
              label: "Organization",
              tooltip: "NPI-2 — a practice or facility, searched by organization name"
            }
          ]
          value: root.searchType
          foreground: root.foreground
          background: "transparent"
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          focusable: false
          onChanged: function (value) {
            root.searchType = value;
            root.refreshAfterFilterChange();
            searchField.forceActiveFocus();
          }
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      Item {
        width: parent.width
        visible: root.results.length > 0
        implicitHeight: visible ? Math.max(resultsHeader.implicitHeight, resultsMeta.implicitHeight) : 0

        PanelSectionHeader {
          id: resultsHeader

          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "PROVIDERS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          id: resultsMeta

          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: NPI.formatCount(root.totalCount) + " shown  ·  " + root.scopeLabel()
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.48
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ListView {
        id: resultList

        width: parent.width
        height: root.resultsHeight
        visible: root.results.length > 0
        clip: true
        model: root.results
        currentIndex: root.selectedIndex
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          required property var modelData
          required property int index

          width: ListView.view.width
          height: body.implicitHeight + Style.space(22)
          radius: Style.cornerRadius / 2
          color: index === root.selectedIndex ? root.selectedBackground : "transparent"

          Rectangle {
            anchors {
              left: parent.left
              right: parent.right
              bottom: parent.bottom
            }
            visible: index < root.results.length - 1 && index !== root.selectedIndex
            height: 1
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
          }

          Column {
            id: body

            anchors {
              left: parent.left
              right: parent.right
              verticalCenter: parent.verticalCenter
              leftMargin: Style.spacing.rowPaddingX
              rightMargin: Style.spacing.rowPaddingX
            }
            spacing: Style.space(4)

            Item {
              width: parent.width
              implicitHeight: Math.max(nameLabel.implicitHeight, npiLabel.implicitHeight)

              Text {
                id: nameLabel

                anchors {
                  left: parent.left
                  right: npiLabel.left
                  top: parent.top
                  rightMargin: Style.space(12)
                }
                text: modelData.name + (modelData.credential !== "" ? ", " + modelData.credential : "")
                textFormat: Text.PlainText
                color: index === root.selectedIndex ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                id: npiLabel

                anchors.right: parent.right
                anchors.top: parent.top
                text: modelData.npi
                textFormat: Text.PlainText
                color: index === root.selectedIndex ? root.selectedText : root.foreground
                opacity: 0.72
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Text {
              width: parent.width
              text: (modelData.taxonomy !== "" ? modelData.taxonomy : "No taxonomy on file") + (modelData.license !== "" ? "  ·  Lic " + modelData.license : "")
              textFormat: Text.PlainText
              color: index === root.selectedIndex ? root.selectedText : root.foreground
              opacity: 0.62
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: modelData.typeLabel + "  ·  " + modelData.location + (modelData.phone !== "" ? "  ·  " + modelData.phone : "") + (modelData.active ? "" : "  ·  DEACTIVATED") + (modelData.otherName !== "" ? "  ·  " + modelData.otherName : "")
              textFormat: Text.PlainText
              color: index === root.selectedIndex ? root.selectedText : root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onEntered: root.selectedIndex = index
            onClicked: function (mouse) {
              root.selectedIndex = index;
              if (mouse.button === Qt.RightButton)
                root.openSelected();
              else
                root.copySelected();
            }
          }
        }
      }

      BorderSurface {
        id: emptyState

        width: parent.width
        visible: root.results.length === 0
        implicitHeight: visible ? Style.space(92) : 0
        color: Style.controlFill(false, false, root.foreground, root.accent)
        borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
        radius: Style.cornerRadius

        Column {
          width: parent.width - Style.space(40)
          anchors.centerIn: parent
          spacing: Style.space(5)

          Text {
            width: parent.width
            text: root.searching ? "Searching the registry…" : root.errorText !== "" ? "Couldn’t load providers" : "Look up a provider"
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            text: root.searching ? "Searching " + root.scopeLabel() : root.errorText !== "" ? root.errorText : "Search by name, by organization, or by a ten-digit NPI"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.48
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(safetyNote.implicitHeight, keyHints.implicitHeight)

        Text {
          id: safetyNote

          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Public registry  ·  no patient identifiers"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.46
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: keyHints

          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "↑↓ select  ·  Enter copy  ·  Ctrl+Enter open  ·  Esc close"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.32
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
