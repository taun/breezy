import BreezyKit
import SwiftUI
import UniformTypeIdentifiers

/// The Media tab's header image: the page banner and the bookshelf thumbnail of a node, made from a picture that is
/// pasted or copied from a web address. The picture is fitted to the site's boxes and saved with the node's commit;
/// an address is only where the picture comes from and is never stored.
struct HeaderImageSection: View {
    @Environment(AppModel.self) private var model
    let workspace: SiteWorkspace
    let slug: String
    let header: NodeHeader

    // This device's choices, restored on relaunch: whether to make a thumbnail, and an address typed but not imported
    // yet, as "slug|address" so only the node it was typed for shows it.
    @AppStorage("header.thumbnail") private var makeThumbnail = true
    @AppStorage("header.address") private var addressRaw = ""
    @State private var importing = false

    private var address: String {
        get { addressRaw.hasPrefix(slug + "|") ? String(addressRaw.dropFirst(slug.count + 1)) : "" }
        nonmutating set { addressRaw = newValue.isEmpty ? "" : "\(slug)|\(newValue)" }
    }

    var body: some View {
        Section {
            if let image = header.image { row("Banner", path: image) }
            if let teaser = header.teaser { row("Thumbnail", path: teaser) }
            Toggle("Make a thumbnail for the bookshelf", isOn: $makeThumbnail)
            HStack {
                PasteButton(supportedContentTypes: [.image]) { providers in
                    guard let provider = providers.first else { return }
                    Task { await paste(provider) }
                }
                .labelStyle(.titleAndIcon)
                Spacer()
                if header.image != nil || header.teaser != nil {
                    Button("Remove", role: .destructive) { run { try workspace.removeHeaderImage(slug: slug) } }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Image address", text: Binding(get: { address }, set: { address = $0 }))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit { Task { await importAddress() } }
                    .disabled(importing)
                if importing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Import") { Task { await importAddress() } }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Header image")
        } footer: {
            Text("The picture is copied into the site, sized for the banner and the thumbnail, and saved with your next commit. The address is not kept.")
        }
    }

    /// A picture in use with its path and a menu to choose another file already in the site.
    private func row(_ title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                AssetMenu(paths: workspace.assetPaths) { chosen in
                    run {
                        let image = title == "Banner" ? chosen : header.image
                        let teaser = title == "Banner" ? header.teaser : chosen
                        try workspace.update(slug) { try $0.setHeader(image: image, teaser: teaser) }
                    }
                }
            }
            PreviewImage(image: MarkdownImage(alt: title, src: path), workspace: workspace)
                .frame(maxHeight: title == "Banner" ? 120 : 90)
            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func run(_ change: () throws -> Void) {
        do { try change() } catch { model.errorMessage = error.localizedDescription }
    }

    private func paste(_ provider: NSItemProvider) async {
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in continuation.resume(returning: data) }
        }
        guard let data else {
            model.errorMessage = "There is no image on the clipboard."
            return
        }
        model.setHeaderImage(slug: slug, from: data, makeThumbnail: makeThumbnail, in: workspace)
    }

    private func importAddress() async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        if await model.importHeaderImage(slug: slug, from: address, makeThumbnail: makeThumbnail) { address = "" }
    }
}
