import AppKit

/// Overlay shown while a saved combination loads: a determinate bar over the
/// pane images and objects still to come. Styled like `MainImageView`'s loading overlay.
public final class RestoreProgressView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1

        detailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail

        for v in [titleLabel, progressBar, detailLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 380),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            detailLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 10),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
    }

    public func update(title: String, done: Int, total: Int, detail: String) {
        titleLabel.stringValue = title
        progressBar.doubleValue = total > 0 ? Double(done) / Double(total) : 1
        detailLabel.stringValue = detail
    }

}
