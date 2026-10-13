import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 1, green: 0.43, blue: 0.25, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952), xRadius: 220, yRadius: 220).fill()
NSColor(calibratedRed: 1, green: 0.96, blue: 0.87, alpha: 1).setFill()
for rect in [NSRect(x: 218,y: 508,width: 128,height: 168), NSRect(x: 358,y: 638,width: 132,height: 180), NSRect(x: 534,y: 638,width: 132,height: 180), NSRect(x: 678,y: 508,width: 128,height: 168)] { NSBezierPath(ovalIn: rect).fill() }
let p = NSBezierPath()
p.move(to: NSPoint(x: 300,y: 290))
p.curve(to: NSPoint(x: 360,y: 480), controlPoint1: NSPoint(x: 236,y: 345), controlPoint2: NSPoint(x: 305,y: 433))
p.curve(to: NSPoint(x: 512,y: 580), controlPoint1: NSPoint(x: 420,y: 535), controlPoint2: NSPoint(x: 435,y: 580))
p.curve(to: NSPoint(x: 664,y: 480), controlPoint1: NSPoint(x: 589,y: 580), controlPoint2: NSPoint(x: 604,y: 535))
p.curve(to: NSPoint(x: 724,y: 290), controlPoint1: NSPoint(x: 719,y: 433), controlPoint2: NSPoint(x: 788,y: 345))
p.curve(to: NSPoint(x: 512,y: 294), controlPoint1: NSPoint(x: 668,y: 238), controlPoint2: NSPoint(x: 586,y: 294))
p.curve(to: NSPoint(x: 300,y: 290), controlPoint1: NSPoint(x: 438,y: 294), controlPoint2: NSPoint(x: 356,y: 238))
p.close(); p.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
