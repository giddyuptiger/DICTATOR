import UIKit

// Note: DictationCore is compiled into this target as source; no import needed.

/// A full, self-contained emoji keyboard rendered INSIDE Dictator.
///
/// Why this exists: iOS does not expose Apple's own emoji keyboard to a keyboard
/// extension — there is no API to show it or jump to it. The only "system" way to
/// reach emoji from a custom keyboard is `advanceToNextInputMode()`, which just
/// cycles to the next *enabled* keyboard (for a user with Japanese installed, that
/// lands on Japanese, not emoji). So, like Gboard and every other third-party
/// keyboard, we build our own. Tapping the emoji key now stays in Dictator and
/// never disturbs the user's other keyboards.
///
/// Features: eight categories with a tab strip, a Recents section, tap-to-insert,
/// and skin-tone variants on long-press for the emoji that support them.
final class EmojiKeyboardView: UIView {

    struct Category {
        let symbol: String     // SF Symbol name for the tab
        let title: String
        let emoji: [String]
    }

    /// Called with the chosen emoji (already skin-toned if the user picked a tone).
    var onPick: ((String) -> Void)?

    /// Colours, driven by the host keyboard's palette so the strip matches.
    var glyphTint: UIColor = .label { didSet { applyColors() } }
    var stripBackground: UIColor = .clear { didSet { applyColors() } }
    var selectedTabBackground: UIColor = .systemGray3 { didSet { applyColors() } }

    private var sections: [Category] = []
    private var tabButtons: [UIButton] = []
    private let tabStrip = UIStackView()
    private var collectionView: UICollectionView!
    private var syncingTabToScroll = false

    private let cellID = "emoji"
    private let headerID = "header"

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Build

    private func buildLayout() {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 6
        layout.headerReferenceSize = CGSize(width: 0, height: 22)
        layout.sectionInset = UIEdgeInsets(top: 2, left: 6, bottom: 8, right: 6)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.showsVerticalScrollIndicator = true
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .none
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(EmojiCell.self, forCellWithReuseIdentifier: cellID)
        collectionView.register(EmojiHeader.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: headerID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.3
        collectionView.addGestureRecognizer(lp)

        tabStrip.axis = .horizontal
        tabStrip.distribution = .fillEqually
        tabStrip.translatesAutoresizingMaskIntoConstraints = false

        addSubview(collectionView)
        addSubview(tabStrip)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),

            tabStrip.topAnchor.constraint(equalTo: collectionView.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    // MARK: - Data

    /// Rebuild sections (Recents first, when any) and refresh the tab strip. Call
    /// this each time the plane is shown so Recents reflect the latest picks.
    func reload() {
        var built: [Category] = []
        let recents = SharedStore.recentEmoji
        if !recents.isEmpty {
            built.append(Category(symbol: "clock", title: "Recently Used", emoji: recents))
        }
        built.append(contentsOf: EmojiData.categories)
        sections = built
        rebuildTabs()
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
        selectTab(0)
    }

    private func rebuildTabs() {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        for (i, cat) in sections.enumerated() {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: cat.symbol), for: .normal)
            b.tag = i
            b.layer.cornerRadius = 5
            b.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            b.accessibilityLabel = cat.title
            tabStrip.addArrangedSubview(b)
            tabButtons.append(b)
        }
        applyColors()
    }

    private func applyColors() {
        tabStrip.backgroundColor = stripBackground
        for b in tabButtons {
            b.tintColor = glyphTint
            b.backgroundColor = .clear
        }
    }

    private func selectTab(_ index: Int) {
        for (i, b) in tabButtons.enumerated() {
            b.backgroundColor = (i == index) ? selectedTabBackground : .clear
        }
    }

    // MARK: - Actions

    @objc private func tabTapped(_ sender: UIButton) {
        let section = sender.tag
        guard section < sections.count, !sections[section].emoji.isEmpty else { return }
        selectTab(section)
        syncingTabToScroll = true
        collectionView.scrollToItem(at: IndexPath(item: 0, section: section),
                                    at: .top, animated: false)
        // Nudge so the section header isn't hidden just under the top edge.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let attrs = self.collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: section)) {
                var y = attrs.frame.minY - 2
                y = min(y, max(0, self.collectionView.contentSize.height - self.collectionView.bounds.height))
                self.collectionView.setContentOffset(CGPoint(x: 0, y: max(0, y)), animated: false)
            }
            self.syncingTabToScroll = false
        }
    }

    private func insert(_ emoji: String) {
        SharedStore.pushRecentEmoji(emoji)
        onPick?(emoji)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Skin tones

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let point = g.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.section < sections.count else { return }
        let base = sections[indexPath.section].emoji[indexPath.item]
        guard let variants = EmojiData.skinToneVariants(for: base) else { return }
        showTonePicker(variants, around: indexPath)
    }

    private var tonePicker: UIView?

    private func showTonePicker(_ variants: [String], around indexPath: IndexPath) {
        dismissTonePicker()
        guard let cellAttrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let cellFrameInSelf = collectionView.convert(cellAttrs.frame, to: self)

        let bar = UIStackView()
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 2
        bar.backgroundColor = selectedTabBackground
        bar.layer.cornerRadius = 8
        bar.layer.masksToBounds = true
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = .init(top: 4, leading: 6, bottom: 4, trailing: 6)
        bar.translatesAutoresizingMaskIntoConstraints = false

        for v in variants {
            let b = UIButton(type: .system)
            b.setTitle(v, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 26)
            b.accessibilityLabel = "Emoji skin tone"
            b.addAction(UIAction { [weak self] _ in
                self?.insert(v)
                self?.dismissTonePicker()
            }, for: .touchUpInside)
            bar.addArrangedSubview(b)
        }

        addSubview(bar)
        let width = CGFloat(variants.count) * 38 + 12
        var x = cellFrameInSelf.midX - width / 2
        x = max(4, min(x, bounds.width - width - 4))
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: width),
            bar.heightAnchor.constraint(equalToConstant: 44),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: max(0, cellFrameInSelf.minY - 48)),
        ])
        tonePicker = bar
    }

    @objc private func dismissTonePicker() {
        tonePicker?.removeFromSuperview()
        tonePicker = nil
    }
}

// MARK: - Collection data source / delegate

extension EmojiKeyboardView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].emoji.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: cellID, for: indexPath) as! EmojiCell
        cell.label.text = sections[indexPath.section].emoji[indexPath.item]
        return cell
    }

    func collectionView(_ cv: UICollectionView,
                        viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let h = cv.dequeueReusableSupplementaryView(ofKind: kind,
                                                    withReuseIdentifier: headerID,
                                                    for: indexPath) as! EmojiHeader
        h.label.text = sections[indexPath.section].title.uppercased()
        h.label.textColor = glyphTint.withAlphaComponent(0.55)
        return h
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        cv.deselectItem(at: indexPath, animated: false)
        dismissTonePicker()
        insert(sections[indexPath.section].emoji[indexPath.item])
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        // Aim for ~8 columns; compute an item size that fills the width evenly.
        guard cv.bounds.width > 1 else { return CGSize(width: 40, height: 40) }
        let inset: CGFloat = 12
        let spacing: CGFloat = 2
        let target: CGFloat = 40
        let usable = cv.bounds.width - inset
        let cols = max(6, floor((usable + spacing) / (target + spacing)))
        let w = floor((usable - (cols - 1) * spacing) / cols)
        return CGSize(width: w, height: w)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !syncingTabToScroll else { return }
        // Sync the tab strip to whatever section is at the top of the view.
        let top = collectionView.contentOffset.y + 4
        for section in 0..<sections.count {
            guard let attrs = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: section)) else { continue }
            if attrs.frame.minY > top {
                selectTab(max(0, section - 1))
                return
            }
        }
        selectTab(max(0, sections.count - 1))
    }
}

// MARK: - Cell + header

private final class EmojiCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 30)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool {
        didSet {
            contentView.backgroundColor = isHighlighted
                ? UIColor.gray.withAlphaComponent(0.25) : .clear
            contentView.layer.cornerRadius = 6
        }
    }
}

private final class EmojiHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
