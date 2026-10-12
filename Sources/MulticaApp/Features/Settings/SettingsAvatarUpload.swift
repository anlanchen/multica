import AppKit
import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

/// Click-to-upload avatar (upstream AvatarUploadControl): picks an image,
/// opens the crop sheet, uploads the 512 px result and hands its URL to the
/// caller, which persists it and reports whether that worked.
struct SettingsAvatarUploadControl: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let value: String?
    var kind: AvatarKind = .member
    let name: String
    var size: CGFloat = 64
    var disabled = false
    var accessibilityLabel: String? = nil
    let onUploaded: (String) async -> Bool

    @State private var picked: SettingsPickedImage?
    @State private var busy = false
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            ZStack {
                AvatarView(name: name, url: value, kind: kind, size: size)
                if !disabled && (hovering || busy) {
                    shape.fill(Color.black.opacity(0.4))
                    if busy {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "camera").foregroundStyle(.white)
                    }
                }
            }
            .frame(width: size, height: size)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
        .opacity(disabled ? 0.6 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibilityLabel ?? tr("common", "avatar_upload.change"))
        .sheet(item: $picked) { image in
            SettingsAvatarCropSheet(image: image, busy: busy, onCancel: { picked = nil }, onCropped: upload)
                .interactiveDismissDisabled(busy)
        }
    }

    private var shape: AnyShape {
        kind == .member ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let image = await SettingsPickedImage.load(url) {
                picked = image
            } else {
                toaster.error(tr("common", "avatar_upload.select_image"))
            }
        }
    }

    private func upload(_ data: Data, _ filename: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let attachment = try await session.api.uploadFile(name: filename, mimeType: "image/jpeg", data: data)
                guard await onUploaded(attachment.url) else { return }
                picked = nil
                toaster.success(tr("common", "avatar_upload.updated"))
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("common", "avatar_upload.failed"), kind: .error)
            }
        }
    }
}

struct SettingsPickedImage: Identifiable, @unchecked Sendable {
    let id = UUID()
    let cgImage: CGImage
    let filename: String

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    static func load(_ url: URL) async -> SettingsPickedImage? {
        await Task.detached(priority: .userInitiated) { () -> SettingsPickedImage? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                  ] as CFDictionary)
            else { return nil }
            return SettingsPickedImage(cgImage: image, filename: url.lastPathComponent)
        }.value
    }
}

/// Avatar cropper (upstream AvatarCropDialog): the image pans, zooms and
/// rotates beneath a fixed round window; the output is a square JPEG.
struct SettingsAvatarCropSheet: View {
    let image: SettingsPickedImage
    let busy: Bool
    let onCancel: () -> Void
    let onCropped: (Data, String) -> Void

    static let outputSize: CGFloat = 512
    private let frameSize: CGFloat = 360
    private let cropDiameter: CGFloat = 300
    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 3

    @State private var zoom: CGFloat = 1
    @State private var rotation = 0
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var pinchStart: CGFloat?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("common", "avatar_crop.title")).font(Theme.Font.title)
            cropArea
            HStack(spacing: 12) {
                Button { setZoom(zoom - 0.1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .help(tr("common", "avatar_crop.zoom_out"))
                Slider(value: Binding(get: { zoom }, set: { setZoom($0) }), in: minZoom...maxZoom)
                    .accessibilityLabel(tr("common", "avatar_crop.zoom"))
                Button { setZoom(zoom + 0.1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(tr("common", "avatar_crop.zoom_in"))
            }
            .disabled(busy || failed)
            HStack {
                Button(tr("common", "avatar_crop.reset")) {
                    zoom = minZoom
                    rotation = 0
                    offset = .zero
                }
                .buttonStyle(.borderless)
                .disabled(busy)
                Spacer()
                Button(tr("common", "avatar_crop.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(action: confirm) {
                    if busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(tr("common", "avatar_crop.uploading"))
                        }
                    } else {
                        Text(tr("common", "avatar_crop.apply"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || failed)
            }
        }
        .padding(20)
        .frame(width: frameSize + 40)
    }

    private var rotatedPixelSize: CGSize {
        let s = image.pixelSize
        return rotation % 180 == 0 ? s : CGSize(width: s.height, height: s.width)
    }

    private var scale: CGFloat {
        let s = rotatedPixelSize
        return cropDiameter / max(1, min(s.width, s.height)) * zoom
    }

    private var cropArea: some View {
        ZStack {
            Color(white: 0.1)
            if failed {
                Text(tr("common", "avatar_crop.load_failed")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .frame(width: image.pixelSize.width * scale, height: image.pixelSize.height * scale)
                    .rotationEffect(.degrees(Double(rotation)))
                    .offset(offset)
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .mask {
                        Rectangle().overlay {
                            Circle().frame(width: cropDiameter, height: cropDiameter).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .allowsHitTesting(false)
                Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                    .frame(width: cropDiameter, height: cropDiameter)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: frameSize, height: frameSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { g in
                    let start = dragStart ?? offset
                    dragStart = start
                    offset = clamp(CGSize(width: start.width + g.translation.width, height: start.height + g.translation.height))
                }
                .onEnded { _ in dragStart = nil }
                .simultaneously(with: MagnifyGesture()
                    .onChanged { g in
                        let start = pinchStart ?? zoom
                        pinchStart = start
                        setZoom(start * g.magnification)
                    }
                    .onEnded { _ in pinchStart = nil })
        )
        .overlay(alignment: .topTrailing) {
            if !failed {
                Button {
                    rotation = (rotation + 90) % 360
                    offset = clamp(offset)
                } label: {
                    Image(systemName: "rotate.right")
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                .padding(8)
                .disabled(busy)
                .help(tr("common", "avatar_crop.rotate"))
            }
        }
        .disabled(busy)
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(maxZoom, max(minZoom, (value * 100).rounded() / 100))
        offset = clamp(offset)
    }

    private func clamp(_ o: CGSize) -> CGSize {
        let s = rotatedPixelSize
        let maxX = max(0, (s.width * scale - cropDiameter) / 2)
        let maxY = max(0, (s.height * scale - cropDiameter) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }

    private func confirm() {
        let out = Self.outputSize
        let k = out / cropDiameter
        let s = scale
        let w = CGFloat(image.cgImage.width), h = CGFloat(image.cgImage.height)
        guard let ctx = CGContext(data: nil, width: Int(out), height: Int(out), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { failed = true; return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: out, height: out))
        ctx.interpolationQuality = .high
        ctx.translateBy(x: out / 2, y: out / 2)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: offset.width, y: -offset.height)
        ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
        ctx.scaleBy(x: s, y: s)
        ctx.draw(image.cgImage, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        guard let cropped = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: cropped).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { failed = true; return }
        let base = (image.filename as NSString).deletingPathExtension
        onCropped(data, "\(base.isEmpty ? "avatar" : base).jpg")
    }
}
