import SwiftUI
import WidgetKit

@main
struct AuraWidgetBundle: WidgetBundle {
    var body: some Widget {
        MusicLiveActivity()
        ReleaseFetchLiveActivity()
    }
}
