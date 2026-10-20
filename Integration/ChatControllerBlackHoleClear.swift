// Telegram-iOS integration: submodules/TelegramUI/Sources/Chat/ChatControllerBlackHoleClear.swift
// (add "//submodules/TelegramUI/Components/Chat/BlackHoleDelete" to TelegramUI/BUILD deps).
// Called from ChatControllerImpl.beginClearHistory — see README.md, step 3.

import Foundation
import UIKit
import Display
import BlackHoleDelete

extension ChatControllerImpl {
    /// Captures the visible messages and the wallpaper before the history is hidden and returns
    /// a function that runs the black hole; nil — fall back to the regular clearing.
    /// The returned function takes `presentUndo`, called when the navigation bar comes back.
    func prepareBlackHoleClearAnimation() -> ((@escaping () -> Void) -> Void)? {
        if UIAccessibility.isReduceMotionEnabled {
            return nil
        }
        let displayNode = self.chatDisplayNode
        let historyContainerView = displayNode.historyNodeContainer.view
        guard !displayNode.historyNodeContainer.isSecret,
              let container = historyContainerView.superview, let window = container.window else {
            return nil
        }

        // Message snapshots: layer.render draws only the node's own layer tree (drawHierarchy would
        // also capture the navigation bar and panels above it).
        var items: [BlackHoleSwallowItem] = []
        var nextId = 0
        displayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
            let view = itemNode.view
            let frame = view.convert(view.bounds, to: container)
            guard frame.intersects(container.bounds), frame.width >= 1.0, frame.height >= 1.0,
                  let image = BlackHoleSnapshot.image(of: view) else {
                return
            }
            items.append(BlackHoleSwallowItem(id: nextId, frame: frame, image: image))
            nextId += 1
        }
        if items.isEmpty {
            return nil
        }
        let backgroundView = displayNode.backgroundNode.view
        let wallpaper = BlackHoleSnapshot.image(of: backgroundView)
        let islandInWindow = BlackHoleLayout.islandRect(screenWidth: window.bounds.width,
                                                        safeAreaTop: window.safeAreaInsets.top,
                                                        narrowIsland: BlackHoleLayout.isNarrowIsland)
        let island = container.convert(islandInWindow, from: window)

        // The history is hidden right after this call (historyAppearsCleared); keep a frozen copy
        // on screen until the animator draws its first frame.
        let placeholder = historyContainerView.snapshotView(afterScreenUpdates: false)
        if let placeholder {
            placeholder.frame = historyContainerView.frame
            container.insertSubview(placeholder, aboveSubview: historyContainerView)
        }

        guard let animator = BlackHoleDeleteAnimator(bundle: BlackHoleDeleteAnimator.resourceBundle()) else {
            placeholder?.removeFromSuperview()
            return nil
        }

        return { [weak self] presentUndo in
            guard let self else {
                placeholder?.removeFromSuperview()
                presentUndo()
                return
            }
            let navigationBarView = self.navigationBar?.view
            // Layer order: wallpaper < backdrop < history < mesh < navigation bar < overlay.
            for view in [animator.backdropView, animator.meshView, animator.overlayView] {
                view.frame = container.bounds
            }
            container.insertSubview(animator.backdropView, aboveSubview: backgroundView)
            container.insertSubview(animator.meshView, aboveSubview: placeholder ?? historyContainerView)
            container.addSubview(animator.overlayView)

            var barsHidden = false
            var undoPresented = false
            animator.onUpdate = { [weak self] state in
                let hide = state.presence > 0.12
                guard hide != barsHidden, let self else {
                    return
                }
                barsHidden = hide
                UIView.animate(withDuration: 0.3) {
                    navigationBarView?.alpha = hide ? 0.0 : 1.0
                }
                if hide {
                    self.statusBar.updateStatusBarStyle(.Hide, animated: true)
                } else {
                    self.updateStatusBarPresentation(animated: true)
                    // The "Chat cleared" toast comes back together with the bars.
                    if !undoPresented {
                        undoPresented = true
                        presentUndo()
                    }
                }
            }
            animator.onCompletion = {
                for view in [animator.backdropView, animator.meshView, animator.overlayView] {
                    view.removeFromSuperview()
                }
                navigationBarView?.alpha = 1.0
                if !undoPresented {
                    undoPresented = true
                    presentUndo()
                }
                animator.onUpdate = nil
                animator.onCompletion = nil
            }
            animator.start(items: items, wallpaper: wallpaper, island: island, onStart: {
                placeholder?.removeFromSuperview()
            })
        }
    }
}

private enum BlackHoleSnapshot {
    static func image(of view: UIView) -> CGImage? {
        guard view.bounds.width >= 1.0, view.bounds.height >= 1.0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }.cgImage
    }
}
