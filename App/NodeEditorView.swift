import BreezyKit
import SwiftUI

struct NodeEditorView: View {
    @Environment(AppModel.self) private var model
    let workspace: SiteWorkspace
    let slug: String
    @Environment(\.scenePhase) private var scenePhase
    // Restored on relaunch: preview mode, and which field of which node was being edited ("slug|field").
    @AppStorage("editor.preview") private var showPreview = false
    @AppStorage("editor.focus") private var focusRaw = ""
    @FocusState private var focus: Field?

    // The selected tab, restored on relaunch.
    @AppStorage("editor.tab") private var tabRaw = Tab.title.rawValue
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Whether the on-screen keyboard is up (not with a hardware keyboard).
    @State private var keyboardShown = false
    #endif

    enum Field: String { case title, summary, body }

    enum Tab: String, CaseIterable, Identifiable {
        case title = "Title", date = "Date", links = "Links", media = "Media", body = "Body"
        var id: String { rawValue }

        /// The stored tab, or Title for a name that is not a tab (renamed, such as "Basics", or from another build).
        /// The stored value is left as is, so a build that knows that tab still finds it.
        init(stored: String) { self = Tab(rawValue: stored) ?? .title }

        /// Shown instead of the name where five names do not fit (compact width: iPhone, narrow iPad windows).
        var symbol: String {
            switch self {
            case .title: "textformat"
            case .date: "calendar"
            case .links: "link"
            case .media: "photo.on.rectangle"
            case .body: "text.alignleft"
            }
        }
    }

    private var tab: Tab { Tab(stored: tabRaw) }

    /// Typed, so a stored name that is no longer a tab still selects the Title segment it falls back to.
    private var tabBinding: Binding<Tab> { Binding(get: { tab }, set: { tabRaw = $0.rawValue }) }

    /// Compact width (iPhone, narrow iPad windows): symbol tabs, and segmented controls at the large size so each
    /// segment is a full-size touch target (iOS 26 and later; earlier versions keep the standard height).
    /// Shared by the tab and Edit/Preview pickers so the two stay the same height.
    private var segmentSize: ControlSize { compact ? .large : inheritedSize }
    @Environment(\.controlSize) private var inheritedSize

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// Segmented everywhere, like Edit/Preview (issue #17); symbols at compact width, names elsewhere. The section
    /// header below it names the selected tab.
    private var tabPicker: some View {
        Picker("Section", selection: tabBinding) {
            ForEach(Tab.allCases) { t in
                Group {
                    if compact { Image(systemName: t.symbol).accessibilityLabel(t.rawValue) } else { Text(t.rawValue) }
                }
                .tag(t)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(segmentSize)
    }

    @ViewBuilder private var issuesBanner: some View {
        let issues = workspace.issues(for: slug)
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(issues, id: \.message) { issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal) // in line with the field text below
        }
    }

    @ViewBuilder private func titleSection(_ node: NodeFile) -> some View {
        Section("Title") {
            TextField("Title", text: bind(\.title) { try $0.setTitle($1) })
                .focused($focus, equals: .title)
            TypeField(type: bind(\.type) { try $0.setType($1) }, known: workspace.types)
            TextField("Summary", text: bind(\.summary) { try $0.setSummary($1) }, axis: .vertical)
                .focused($focus, equals: .summary)
            CommitTextField("Tags, comma separated", value: node.tags.joined(separator: ", ")) { text in
                edit { try $0.setTags(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }
            }
            Toggle("Draft (not published)", isOn: bind(\.draft) { try $0.setDraft($1) })
        }
    }

    @ViewBuilder private func media(_ node: NodeFile) -> some View {
        Section("Media") {
            ForEach(NodeFile.stringKeys, id: \.self) { key in
                HStack {
                    TextField(key.capitalized, text: Binding(
                        get: { node.strings[key] ?? "" },
                        set: { v in edit { try $0.setString(key, v) } }))
                        .autocorrectionDisabled()
                    if key == "slides" || key == "archive" {
                        AssetMenu(paths: workspace.assetPaths) { path in edit { try $0.setString(key, path) } }
                    }
                }
            }
        }
    }

    private var controlsHidden: Bool {
        #if os(iOS)
        Self.hidesControls(compactHeight: verticalSizeClass == .compact, bodyFocused: focus == .body, keyboardShown: keyboardShown)
        #else
        false
        #endif
    }

    /// Typing in landscape on iPhone leaves only a sliver above the keyboard: the controls step aside while the
    /// on-screen keyboard is up, so the text gets all of it, and return when it goes away (drag the text down). Never
    /// without the on-screen keyboard (a hardware keyboard, or focus restored before it appears): nothing could bring
    /// the controls back.
    static func hidesControls(compactHeight: Bool, bodyFocused: Bool, keyboardShown: Bool) -> Bool {
        compactHeight && bodyFocused && keyboardShown
    }

    /// The tab picker and any validation issues, at the top of every tab.
    private var tabHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            tabPicker
            issuesBanner
        }
    }

    /// The Body tab fills the screen (or window) and the editor scrolls itself, keeping the cursor in view as one
    /// types. Not a Form: a form row that grows with the text made the page jump (iPhone landscape) and overflowed
    /// the window on the Mac. Styled like the other tabs' grouped forms.
    @ViewBuilder private func bodyTab(_ node: NodeFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !controlsHidden {
                tabHeader.padding(.vertical, 8)
                GroupedStyle.header("Body")
            }
            VStack(spacing: 0) {
                if !controlsHidden {
                    Picker("Body", selection: $showPreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(segmentSize)
                    .padding(12)
                    Divider().padding(.horizontal, 12)
                }
                if showPreview {
                    ScrollView { MarkdownPreview(node: node, workspace: workspace).padding() }
                } else {
                    BodyEditor(text: Binding(get: { node.body }, set: { v in edit { $0.setBody(v) } }), slug: slug)
                        .focused($focus, equals: .body)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively) // drag the text down to put the keyboard (and controls) away
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            #if os(macOS)
            .frame(minHeight: 160, maxHeight: .infinity) // a short window still leaves some lines to edit
            #else
            .frame(maxHeight: .infinity)
            #endif
            .background(GroupedStyle.card, in: RoundedRectangle(cornerRadius: GroupedStyle.cornerRadius))
            .padding(.bottom, controlsHidden ? 0 : 8)
        }
        .padding(.horizontal, GroupedStyle.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GroupedStyle.page)
        .animation(.default, value: controlsHidden)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false }
        #endif
    }

    private var node: NodeFile? { workspace.nodes[slug] }

    var body: some View {
        if let node {
            // The form's identity changes with the tab (below); the restore task and focus handler sit on this
            // container instead, so they run once per opened node rather than on every tab change.
            VStack(spacing: 0) {
            if tab == .body {
                bodyTab(node)
            } else {
            // A grouped form for the other tabs: the tab picker is its first row and scrolls with the fields.
            Form {
                Section {
                    tabHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch tab {
                case .title: titleSection(node)
                case .date: DateSection(date: node.date) { new in edit { try $0.setDate(new) } }
                case .links: LinkEditorView(workspace: workspace, slug: slug)
                case .media: media(node)
                case .body: EmptyView() // never: the Body tab is bodyTab (the switch must still be exhaustive)
                }
            }
            .formStyle(.grouped)
            // Each tab opens at the top rather than at the last tab's scroll position.
            .id(tab)
            .scrollDismissesKeyboard(.interactively)
            }
            }
            .onChange(of: focus) { _, f in
                // Leaving the app also clears focus; only record changes made while in use.
                if scenePhase == .active { focusRaw = f.map { "\(slug)|\($0.rawValue)" } ?? "" }
            }
            .task {
                // Put the cursor back where it was, on the tab that holds it.
                let parts = focusRaw.split(separator: "|")
                guard parts.count == 2, parts[0] == slug, let f = Field(rawValue: String(parts[1])) else { return }
                if f == .body && showPreview { return }
                tabRaw = (f == .body ? Tab.body : Tab.title).rawValue
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return } // the node was closed
                focus = f
            }
            .navigationTitle(node.title)
            .toolbar {
                if workspace.isModified(slug) {
                    ToolbarItem { Button("Revert") { try? workspace.revert(slug) } }
                }
            }
        }
    }

    /// Two-way binding to a decoded field whose setter rewrites the front matter.
    private func bind<T>(_ get: KeyPath<NodeFile, T>, _ set: @escaping (inout NodeFile, T) throws -> Void) -> Binding<T> {
        Binding(
            get: { workspace.nodes[slug]![keyPath: get] },
            set: { v in edit { try set(&$0, v) } })
    }

    private func edit(_ change: (inout NodeFile) throws -> Void) {
        do { try workspace.update(slug, change) } catch { model.errorMessage = error.localizedDescription }
    }
}

/// The look of a grouped form, for the Body tab, which is not a Form.
private enum GroupedStyle {
    #if os(iOS)
    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let margin: CGFloat = 16
    static var cornerRadius: CGFloat { if #available(iOS 26, *) { 26 } else { 10 } }
    #else
    static let page = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .textBackgroundColor)
    static let margin: CGFloat = 20
    static let cornerRadius: CGFloat = 8
    #endif

    /// A section header like the forms' ("Body").
    static func header(_ title: String) -> some View {
        #if os(iOS)
        Group {
            if #available(iOS 26, *) {
                Text(title).font(.subheadline.weight(.semibold))
            } else {
                Text(title).font(.footnote).textCase(.uppercase)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
        #else
        Text(title).font(.headline).padding(.horizontal, 4).padding(.bottom, 6)
        #endif
    }
}

/// Date with year or day precision; year precision is the site's bare-year style.
struct DateSection: View {
    let date: NodeDate?
    let set: (NodeDate?) -> Void

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var year: Int { Int(date?.iso.prefix(4) ?? "") ?? Calendar.current.component(.year, from: .now) }

    var body: some View {
        Section("Date") {
            Toggle("Dated", isOn: Binding(get: { date != nil }, set: { on in
                set(on ? NodeDate(iso: "\(Calendar.current.component(.year, from: .now))-01-01", precision: .year) : nil)
            }))
            if let date {
                Picker("Precision", selection: Binding(get: { date.precision }, set: { p in
                    set(date.changingPrecision(to: p, todayISO: Self.toISO(.now)))
                })) {
                    Text("Year").tag(DatePrecision.year)
                    Text("Day").tag(DatePrecision.day)
                }
                .pickerStyle(.segmented)
                if date.precision == .year {
                    TextField("Year", value: Binding(get: { year }, set: { y in
                        if (1000...9999).contains(y) { set(NodeDate(iso: String(format: "%04d-01-01", y), precision: .year)) }
                    }), format: .number.grouping(.never))
                } else {
                    DatePicker("Day", selection: Binding(get: { Self.toDate(date.iso) }, set: { d in
                        set(NodeDate(iso: Self.toISO(d), precision: .day))
                    }), displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                }
            }
        }
    }

    static func toDate(_ iso: String) -> Date {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return .now }
        return utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) ?? .now
    }

    static func toISO(_ d: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }
}

/// Picks one of the existing files under src/assets.
struct AssetMenu: View {
    let paths: [String]
    let pick: (String) -> Void

    private var groups: [(String, [String])] {
        Dictionary(grouping: paths) { $0.split(separator: "/").dropFirst().first.map(String.init) ?? "" }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        Menu {
            ForEach(groups, id: \.0) { folder, files in
                Menu(folder) { ForEach(files, id: \.self) { p in Button((p as NSString).lastPathComponent) { pick(p) } } }
            }
        } label: {
            Image(systemName: "folder")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Choose an existing asset")
    }
}
