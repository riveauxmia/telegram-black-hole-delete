// BlackHoleDelete — minimal UIKit demo of the integration (not needed in Telegram-iOS).
// A fake chat: wallpaper, bubbles, navigation bar with "Clear History". Shows the exact calls the
// host makes: snapshots → hide content → start → nav bar/status bar by presence → empty state.

import UIKit

final class DemoViewController: UIViewController {
    private let wallpaper = UIImageView()
    private let content = UIView()
    private let navBar = UIView()
    private let emptyLabel = UILabel()
    private var bubbles: [(id: Int, view: UIView)] = []
    private var animator: BlackHoleDeleteAnimator?
    private var navHidden = false

    // The hole covers the status bar area. Toggling the system status bar mid-animation costs UIKit
    // a dropped frame, so the demo keeps it hidden (Telegram-iOS: see README.md, "Status bar").
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        wallpaper.contentMode = .scaleAspectFill
        view.addSubview(wallpaper)
        view.addSubview(content)

        animator = BlackHoleDeleteAnimator()
        if let animator {
            // Order: wallpaper < backdrop < chat content < mesh < nav bar < overlay.
            view.insertSubview(animator.backdropView, aboveSubview: wallpaper)
            view.insertSubview(animator.meshView, aboveSubview: content)
            animator.prewarm()
        }

        navBar.backgroundColor = UIColor(white: 1, alpha: 0.75)
        let title = UILabel()
        title.text = "Ava Hamilton"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textAlignment = .center
        title.tag = 1
        navBar.addSubview(title)
        let clear = UIButton(type: .system)
        clear.setTitle("Clear History", for: .normal)
        clear.titleLabel?.font = .systemFont(ofSize: 17)
        clear.tag = 2
        clear.addTarget(self, action: #selector(clearHistory), for: .touchUpInside)
        navBar.addSubview(clear)
        view.addSubview(navBar)
        if let animator { view.addSubview(animator.overlayView) }

        emptyLabel.text = "No messages here yet..."
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .white
        emptyLabel.textAlignment = .center
        emptyLabel.backgroundColor = UIColor(white: 0, alpha: 0.25)
        emptyLabel.layer.cornerRadius = 14
        emptyLabel.layer.masksToBounds = true
        emptyLabel.alpha = 0
        content.addSubview(emptyLabel)
        makeBubbles()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // -autoplay YES: clear the history by itself every 5 s (for recording).
        if UserDefaults.standard.bool(forKey: "autoplay") {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.clearHistory() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.clearHistory() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        wallpaper.frame = bounds
        content.frame = bounds
        if wallpaper.image?.size != bounds.size { wallpaper.image = Self.wallpaperImage(size: bounds.size) }
        // All three animator views cover the whole screen, aligned with window coordinates.
        animator?.backdropView.frame = bounds
        animator?.meshView.frame = bounds
        animator?.overlayView.frame = bounds
        let top = view.safeAreaInsets.top
        navBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top + 52)
        navBar.viewWithTag(1)?.frame = CGRect(x: 0, y: top + 8, width: bounds.width, height: 36)
        navBar.viewWithTag(2)?.frame = CGRect(x: 12, y: top + 8, width: 120, height: 36)
        emptyLabel.frame = CGRect(x: bounds.midX - 110, y: bounds.midY - 18, width: 220, height: 36)
        layoutBubbles()
    }

    private func makeBubbles() {
        let texts: [(String, Bool)] = [
            ("Ciao from Rome! 🇮🇹", false), ("Send pics!!", true), ("Don't tell mom yet, but I got the job!", false),
            ("WHAT. Congrats!!", true), ("Celebrating with a view", false), ("Dinner when I'm back? Table for four at 8.", false),
            ("Be there.", true), ("Can't wait to see you", false), ("Same! 🥂", true),
        ]
        for (index, (text, outgoing)) in texts.enumerated() {
            let bubble = UIView()
            bubble.backgroundColor = outgoing ? UIColor(red: 0.88, green: 1.0, blue: 0.78, alpha: 1) : .white
            bubble.layer.cornerRadius = 17
            let label = UILabel()
            label.text = text
            label.numberOfLines = 0
            label.font = .systemFont(ofSize: 17)
            label.tag = outgoing ? 1 : 0
            bubble.addSubview(label)
            content.addSubview(bubble)
            bubbles.append((index + 1, bubble))
        }
    }

    private func layoutBubbles() {
        let width = view.bounds.width
        var y = view.safeAreaInsets.top + 70
        for (_, bubble) in bubbles {
            guard let label = bubble.subviews.first as? UILabel else { continue }
            let size = label.sizeThatFits(CGSize(width: width * 0.7, height: .greatestFiniteMagnitude))
            let frame = CGRect(x: label.tag == 1 ? width - size.width - 40 : 12, y: y, width: size.width + 28, height: size.height + 16)
            bubble.frame = frame
            label.frame = CGRect(x: 14, y: 8, width: size.width, height: size.height)
            y = frame.maxY + 8
        }
    }

    @objc private func clearHistory() {
        guard let animator, !animator.isRunning, let window = view.window else { return }
        // 1. Snapshots of the visible messages in window coordinates.
        let items: [BlackHoleSwallowItem] = bubbles.compactMap { id, bubble in
            guard let image = Self.snapshot(bubble) else { return nil }
            return BlackHoleSwallowItem(id: id, frame: bubble.convert(bubble.bounds, to: window), image: image)
        }
        // 2. Wallpaper snapshot at screen size.
        let wallpaperImage = Self.snapshot(wallpaper)
        // 3. Island frame.
        let island = BlackHoleLayout.islandRect(screenWidth: window.bounds.width, safeAreaTop: window.safeAreaInsets.top,
                                                narrowIsland: BlackHoleLayout.isNarrowIsland)
        animator.onUpdate = { [weak self] state in self?.setNavHidden(state.presence > 0.12) }
        animator.onSwallowed = { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.emptyLabel.alpha = 1 }
        }
        animator.onCompletion = { [weak self] in
            // Demo only: bring the messages back after a pause to replay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                UIView.animate(withDuration: 0.3) {
                    self?.emptyLabel.alpha = 0
                    self?.bubbles.forEach { $0.view.alpha = 1 }
                }
            }
        }
        animator.start(items: items, wallpaper: wallpaperImage, island: island) { [weak self] in
            // 4. The animator draws the messages from now on — hide the real ones.
            self?.bubbles.forEach { $0.view.alpha = 0 }
        }
    }

    private func setNavHidden(_ hidden: Bool) {
        guard hidden != navHidden else { return }
        navHidden = hidden
        UIView.animate(withDuration: 0.3) {
            self.navBar.alpha = hidden ? 0 : 1
        }
    }

    private static func snapshot(_ view: UIView) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        // layer.render — only this view's own layer tree. drawHierarchy would capture what is on
        // screen in this rect, including views above it (the nav bar over the wallpaper).
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }.cgImage
    }

    private static func wallpaperImage(size: CGSize) -> UIImage? {
        guard size.width > 0 else { return nil }
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.85, green: 0.89, blue: 0.62, alpha: 1).cgColor,
                          UIColor(red: 0.53, green: 0.72, blue: 0.52, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor(white: 0, alpha: 0.08).setStroke()
            for x in stride(from: CGFloat(10), to: size.width, by: 46) {
                for y in stride(from: CGFloat(10), to: size.height, by: 46) {
                    UIBezierPath(ovalIn: CGRect(x: x + (y.truncatingRemainder(dividingBy: 92) == 10 ? 0 : 23), y: y, width: 14, height: 14)).stroke()
                }
            }
        }
    }
}

@main
final class DemoAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = DemoSceneDelegate.self
        return configuration
    }
}

final class DemoSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = DemoViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
