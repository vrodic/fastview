import AppKit

/// An optional model the app downloads on request and can delete again.
public protocol DownloadableModel: AnyObject {
    /// Short name, e.g. "AI object removal model (LaMa)".
    var displayName: String { get }
    /// Where it comes from and its licence, for the confirmation.
    var sourceDescription: String { get }
    var approximateDownloadSize: String { get }
    var isInstalled: Bool { get }
    var isDownloading: Bool { get }
    /// Size on disk once installed.
    var installedSize: String? { get }
    /// The folder the installed model is kept in (removed by `deleteModel`).
    var installLocation: URL { get }
    /// Handlers run on the main queue; progress is 0...1.
    func download(progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void)
    func cancelDownload()
    func deleteModel()
}

/// Asks before downloading a model, then shows its progress with a Cancel button.
public final class ModelDownloadPanel: NSWindowController {
    private static var current: [ObjectIdentifier: ModelDownloadPanel] = [:]

    private let model: DownloadableModel

    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Starting download…")
    private var completion: ((Bool) -> Void)?

    /// Confirms with the user, downloads and installs the model; `completion(true)` once it is ready.
    public static func run(_ model: DownloadableModel, completion: @escaping (Bool) -> Void) {
        if let current = current[ObjectIdentifier(model)] {
            current.showWindow(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Download the \(model.displayName)?"
        alert.informativeText = "FastView will download about \(model.approximateDownloadSize) from \(model.sourceDescription) and keep it in Application Support. You can delete it later from Options → AI Models."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            completion(false)
            return
        }
        let panel = ModelDownloadPanel(model: model)
        panel.completion = completion
        current[ObjectIdentifier(model)] = panel
        panel.showWindow(nil)
        panel.window?.center()
        panel.start()
    }

    /// Confirms and deletes an installed model.
    public static func confirmDelete(_ model: DownloadableModel) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete the \(model.displayName)?"
        alert.informativeText = "This permanently deletes the folder\n\n\(model.installLocation.path)\n\nfreeing \(model.installedSize ?? "its disk space"). You can download the model again at any time."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        model.deleteModel()
        return true
    }

    private init(model: DownloadableModel) {
        self.model = model
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Downloading AI Model"
        super.init(window: window)

        let title = NSTextField(labelWithString: model.displayName.prefix(1).uppercased() + model.displayName.dropFirst())
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        statusLabel.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [title, progressBar, statusLabel, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func start() {
        model.download(progress: { [weak self] fraction in
            guard let self = self else { return }
            self.progressBar.doubleValue = fraction
            self.statusLabel.stringValue = fraction < 1
                ? "\(Int(fraction * 100))% of \(self.model.approximateDownloadSize)"
                : "Preparing the model…"
        }, completion: { [weak self] error in
            self?.finish(error)
        })
    }

    @objc private func cancelAction() {
        model.cancelDownload()
    }

    private func finish(_ error: Error?) {
        close()
        Self.current[ObjectIdentifier(model)] = nil
        if let error = error as NSError?, !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) {
            let alert = NSAlert()
            alert.messageText = "The AI Model Could Not Be Installed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        completion?(error == nil)
        completion = nil
    }
}
