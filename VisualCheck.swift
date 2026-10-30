import AppKit
import SwiftUI

/// Development-only capture of this application's own window. Does not capture
/// the desktop or other applications and needs no screen-recording permission.
@MainActor enum VisualCheck {
    static var ran = false
    static func run(_ model:PerformanceModel) async {
        guard !ran else {return};ran = true
        try? await Task.sleep(nanoseconds:1_000_000_000)
        guard let window = NSApp.windows.first(where:{$0.title == "Contour" && $0.isVisible}) else {return}
        let directory = model.dataDirectory.appendingPathComponent("screenshots",isDirectory:true)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var results:[[String:Any]] = []
        for (name,size,dark,four) in [("two-decks-light",NSSize(width:1420,height:900),false,false),("two-decks-compact",NSSize(width:1100,height:740),false,false),("four-decks-dark",NSSize(width:1420,height:900),true,true)] {
            model.qaAppearance = dark ? .dark : .light
            NSApp.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            model.setFourDecks(four)
            window.setContentSize(size)
            try? await Task.sleep(nanoseconds:600_000_000)
            guard let view = window.contentView else {continue}
            view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:rep)
                if let png = rep.representation(using:.png,properties:[:]) {
                    let path = directory.appendingPathComponent(name+".png");try? png.write(to:path)
                    results.append(["name":name,"path":path.path,"width":rep.pixelsWide,"height":rep.pixelsHigh])
                }
            }
        }
        model.qaAppearance = nil;NSApp.appearance = nil;window.appearance = nil;model.setFourDecks(false)
        window.setContentSize(NSSize(width:1420,height:900))
        if let data = try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:directory.appendingPathComponent("captures.json"))}
        model.shutdown();NSApp.terminate(nil)
    }
}
