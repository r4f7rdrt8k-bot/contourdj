import AppKit
import Foundation
let root = CommandLine.arguments[1]
for size in [16,32,64,128,256,512,1024] {
 let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
 let s=CGFloat(size);NSColor(calibratedRed:0.12,green:0.16,blue:0.23,alpha:1).setFill()
 NSBezierPath(roundedRect:NSRect(x:0,y:0,width:s,height:s),xRadius:s*0.22,yRadius:s*0.22).fill()
 let colors=[NSColor(calibratedRed:0.28,green:0.65,blue:1,alpha:1),NSColor(calibratedRed:1,green:0.64,blue:0.28,alpha:1)]
 for row in 0..<2 {
  colors[row].setStroke()
  let path=NSBezierPath();path.lineWidth=s*0.043;path.lineCapStyle = .round
  for n in 0..<13 {
   let x=s*(0.17+Double(n)*0.055)
   let env=pow(max(0,1-abs(Double(n)-6)/7),0.8)
   let h=s*(0.02+0.10*env*(0.45+0.55*abs(sin(Double(n)*1.4+Double(row)))))
   let y=s*(row == 0 ? 0.63 : 0.37)
   path.move(to:NSPoint(x:x,y:y-h));path.line(to:NSPoint(x:x,y:y+h))
  }
  path.stroke()
 }
 NSGraphicsContext.restoreGraphicsState()
 guard let png=rep.representation(using:.png,properties:[:]) else {fatalError("Could not render icon")}
 let entries:[String]
 switch size {case 16:entries=["icon_16x16.png"];case 32:entries=["icon_16x16@2x.png","icon_32x32.png"];case 64:entries=["icon_32x32@2x.png"];case 128:entries=["icon_128x128.png"];case 256:entries=["icon_128x128@2x.png","icon_256x256.png"];case 512:entries=["icon_256x256@2x.png","icon_512x512.png"];default:entries=["icon_512x512@2x.png"]}
 for name in entries {try png.write(to:URL(fileURLWithPath:root).appendingPathComponent(name))}
}
