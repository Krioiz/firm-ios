import ActivityKit
import Foundation

// The open basket on the lock screen and in the Dynamic Island. Shared by the app (which starts
// the activity and hands its push token to the server) and the widget extension (which draws it).
// The server updates it over APNs every minute or so, so it keeps ticking with the app closed.
// Plain numbers only (no Date): the server writes this JSON by hand.
struct BasketAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var netKr: Double          // the basket's result if it closed now, after fee and funding
        var netBp: Double
        var best: String; var bestBp: Double
        var worst: String; var worstBp: Double
        var updated: Double        // unix seconds
    }
    var book: String               // "kraken-1h"
    var title: String              // "Momentum-kurven"
    var closesAt: Double           // unix seconds
}
