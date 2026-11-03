import AppKit
import ColorKit
import PixelEngine

/// Remembers the soft proof's intent and paper simulation between
/// launches. The target itself is not remembered (a profile file may have
/// moved); the way it is proofed is a working habit worth keeping.
struct SoftProofOptionsStore {
    let defaults: UserDefaults
    static let key = "latent.softProofOptions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var options: SoftProofOptions {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let options = try? JSONDecoder().decode(SoftProofOptions.self, from: data) else { return SoftProofOptions() }
            return options
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) }
        }
    }
}

extension EditorModel {
    // MARK: - Monitor gamut warning

    /// Builds the table of colours this screen can't show, from the
    /// screen's own profile (Display P3 when the screen reports none), and
    /// re-renders. The table is only used while proofing.
    func rebuildMonitorGamut(rendering: Bool = true) {
        defer { if rendering { rerender() } }
        guard monitorGamutWarning else { monitorGamutLUT = nil; return }
        monitorGamutLUT = try? SoftProofLUT.gamutCheck(Self.monitorTarget())
    }

    /// The screen the editor is on, as a proof target. A screen whose
    /// profile can't be read is treated as Display P3, which is what
    /// Apple's own displays are.
    static func monitorTarget(screen: NSScreen? = NSApp?.keyWindow?.screen ?? NSScreen.main) -> SoftProofTarget {
        guard let screen, let space = screen.colorSpace?.cgColorSpace,
              let data = space.copyICCData() as Data? else { return .displayP3 }
        return .profile(name: screen.localizedName, data: data)
    }

    // MARK: - Proof copy

    /// The snapshot name a proof copy gets for the current target.
    static func proofCopyName(for target: SoftProofTarget) -> String { "Proof — \(target.displayName)" }

    /// Whether a proof copy for the current target already exists, so the
    /// button can say it will be replaced.
    var hasProofCopy: Bool { snapshots.contains { $0.name == Self.proofCopyName(for: proofTarget) } }

    /// Keeps the edit as it is now as a named snapshot for this target,
    /// "Proof — <profile>". A snapshot rather than a virtual copy: the
    /// edit kept beside the photo under a name, which is what a proof
    /// copy is for: the version adjusted for this paper, to come back to.
    /// Saving again for the same target replaces it, like any snapshot.
    func createProofCopy() {
        guard hasImage, proofEnabled else { return }
        saveSnapshot(named: Self.proofCopyName(for: proofTarget))
    }
}
