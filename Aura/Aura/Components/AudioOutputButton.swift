import SwiftUI
import AVKit
import AVFoundation

struct AirPlayButton: UIViewRepresentable {
    var accentColor: UIColor = .systemPink

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = accentColor
        picker.tintColor = .white.withAlphaComponent(0.6)
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = accentColor
    }
}

// MARK: - Audio Route Monitor

@Observable
final class AudioRouteMonitor {
    static let shared = AudioRouteMonitor()
    var routeIcon: String = "airplayaudio"
    var isExternalRoute: Bool = false

    private init() {
        updateRoute()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateRoute()
        }
    }

    func updateRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let output = route.outputs.first else {
            routeIcon = "airplayaudio"
            isExternalRoute = false
            return
        }

        switch output.portType {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            let name = output.portName.lowercased()
            if name.contains("airpod") {
                routeIcon = "airpodspro"
            } else {
                routeIcon = "hifispeaker.fill"
            }
            isExternalRoute = true
        case .headphones:
            routeIcon = "headphones"
            isExternalRoute = true
        case .airPlay:
            routeIcon = "airplayaudio"
            isExternalRoute = true
        case .usbAudio:
            routeIcon = "cable.connector"
            isExternalRoute = true
        case .builtInSpeaker, .builtInReceiver:
            routeIcon = "iphone"
            isExternalRoute = false
        default:
            routeIcon = "airplayaudio"
            isExternalRoute = false
        }
    }
}

// MARK: - Smart Audio Output Button

/// Container that forwards touches to a hidden AVRoutePickerView
class AudioOutputContainerView: UIView {
    let picker = AVRoutePickerView()
    let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        // Custom icon (visible)
        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tag = 999
        addSubview(iconView)
        // 40, not 28. An SF Symbol's UIImage is bigger than its ink, so a 28pt box made
        // scaleAspectFit shrink the whole image to ~70% — airpodspro drew 51px of ink
        // where the raw symbol draws 73px, i.e. visibly shorter than the .title2 icons
        // around it. At 40 nothing is clamped and the glyph lands on the same optical
        // line as its neighbours.
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
        ])

        // Hidden route picker (off-screen but in view hierarchy so it works)
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.isHidden = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 0.1),
            picker.heightAnchor.constraint(equalToConstant: 0.1),
        ])
        picker.clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Find the route picker's internal button and trigger it
        triggerRoutePicker()
    }

    private func triggerRoutePicker() {
        // AVRoutePickerView has an internal UIButton; simulate a tap on it
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
    }
}

struct AudioOutputButton: UIViewRepresentable {
    var accentColor: UIColor = .systemPink
    var routeIcon: String = "airplayaudio"
    var isExternalRoute: Bool = false

    func makeUIView(context: Context) -> AudioOutputContainerView {
        let container = AudioOutputContainerView()
        updateIcon(in: container)
        return container
    }

    func updateUIView(_ uiView: AudioOutputContainerView, context: Context) {
        updateIcon(in: uiView)
    }

    private func updateIcon(in container: AudioOutputContainerView) {
        // Sizes are per-symbol because each glyph fills its em box differently. These are
        // the intended values; they only render true now that the icon box (40) no longer
        // scales the image down.
        let pointSize: CGFloat = switch routeIcon {
        case "airpodspro": 28
        case "iphone": 19
        default: 22
        }
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        container.iconView.image = UIImage(systemName: routeIcon, withConfiguration: config)
        container.iconView.tintColor = isExternalRoute ? accentColor : .white.withAlphaComponent(0.6)
    }
}

struct AudioOutputButtonWrapper: View {
    var accentColor: Color
    @State private var routeMonitor = AudioRouteMonitor.shared

    var body: some View {
        AudioOutputButton(
            accentColor: UIColor(accentColor),
            routeIcon: routeMonitor.routeIcon,
            isExternalRoute: routeMonitor.isExternalRoute
        )
        .frame(width: 40, height: 40)
    }
}
