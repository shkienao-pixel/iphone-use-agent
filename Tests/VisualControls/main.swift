import Foundation
import CoreGraphics

enum AgentError:Error { case message(String) }
var checks=0
func expect(_ value:Bool,_ message:String) { precondition(value,message);checks+=1 }
func raster(dark:Bool=false,shape:String="all") -> PhoneRasterImage {
    let w=320,h=640,bg:UInt8=dark ? 5 : 250,fg:UInt8=dark ? 245 : 10
    var bytes=[UInt8](repeating:bg,count:w*h*4)
    for i in stride(from:3,to:bytes.count,by:4) {bytes[i]=255}
    func put(_ x:Int,_ y:Int) { guard x>=0,x<w,y>=0,y<h else{return};let i=(y*w+x)*4;bytes[i]=fg;bytes[i+1]=fg;bytes[i+2]=fg }
    if shape=="all" || shape=="back" {for y in 44...62 {let x=14+abs(y-53)/2;put(x,y);put(x+1,y)}}
    if shape=="all" || shape=="more" {for cx in [281,288,295] {for y in 50...52 {for x in (cx-1)...(cx+1){put(x,y)}}}}
    if shape=="all" || shape=="plus" || shape=="ring" {
        for y in 580...600 {for x in 279...299 {
            let dx=Double(x-289)/10,dy=Double(y-590)/10,r=hypot(dx,dy)
            if abs(r-0.94)<0.09 || (shape != "ring" && ((abs(dx)<0.11 && abs(dy)<0.61)||(abs(dy)<0.11 && abs(dx)<0.61))){put(x,y)}
        }}
    }
    if shape=="close" {for d in 0..<13 {put(16+d,44+d);put(17+d,44+d);put(28-d,44+d);put(29-d,44+d)}}
    return .init(width:w,height:h,rgba:bytes)
}
for dark in [false,true] {
 let image=raster(dark:dark), controls=PhoneVisualControls.detect(in:image)
 for label in ["视觉:返回","视觉:更多","视觉:添加"] {expect(controls.filter{$0.label==label}.count==1,"Detect actual glyph once \(label), dark=\(dark)")}
 expect(controls.allSatisfy{$0.source=="local_visual" && $0.rect.valid},"real pixel evidence has bounded locations")
 expect(PhoneVisualControls.detect(in:raster(dark:dark,shape:"ring")).allSatisfy{$0.label != "视觉:添加"},"a ring alone isn't Add")
 expect(PhoneVisualControls.detect(in:raster(dark:dark,shape:"none")).isEmpty,"blank raster never invents controls")
 expect(PhoneVisualControls.detect(in:raster(dark:dark,shape:"close")).contains{$0.label=="视觉:关闭"},"Cross is locally observed")
}
let invalid=PhoneRasterImage(width:320,height:640,rgba:[])
expect(!invalid.valid && PhoneVisualControls.detect(in:invalid).isEmpty,"bad byte length refuses decoding")
expect(raster().sample(-0.1,0.5)==nil && raster().sample(.nan,0.5)==nil,"pixel coordinates must be actual normalized values")
let rgba:[UInt8]=[255,0,0,255,0,255,0,255,0,0,255,255,255,255,255,255]
let provider=CGDataProvider(data:Data(rgba) as CFData)!
let image=CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
let actual=PhoneRasterEvidence.raster(image,maxWidth:2)!
expect(actual.sample(0.25,0.25)!.red>0.9 && actual.sample(0.25,0.25)!.blue<0.1,"native raster preserves top pixel orientation")
expect(actual.sample(0.25,0.75)!.blue>0.9,"native raster preserves bottom pixel orientation")
expect(PhoneRasterEvidence.sha256(Data("abc".utf8))=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","screenshot digest is real SHA256")
func dotRaster(_ boxes:[(Int,Int,Int,Int)],dark:Bool=false)->PhoneRasterImage {
    let width=320,height=640,bg:UInt8=dark ? 5 : 250,fg:UInt8=dark ? 245 : 10
    var bytes=[UInt8](repeating:bg,count:width*height*4)
    for index in stride(from:3,to:bytes.count,by:4){bytes[index]=255}
    for (x,y,w,h) in boxes {for row in y..<(y+h) {for column in x..<(x+w) {
        let index=(row*width+column)*4
        bytes[index]=fg;bytes[index+1]=fg;bytes[index+2]=fg
    }}}
    return .init(width:width,height:height,rgba:bytes)
}
func more(_ boxes:[(Int,Int,Int,Int)])->[PhoneUIElement] {
    PhoneVisualControls.detect(in:dotRaster(boxes)).filter{$0.label=="视觉:更多"}
}
for dark in [false,true] {
    let boxes=(0..<28).flatMap {column in (0..<14).map {row in (233+column*3,22+row*3,1,1)}}
    let hints=PhoneVisualControls.detect(in:dotRaster(boxes,dark:dark))
    expect(hints.count==24,"Dense dot noise keeps the existing raw detection cap")
    expect(hints.first?.rect == .init(x:233.0/320,y:22.0/640,width:7.0/320,height:1.0/640),"Dense dots retain the first original ordered hint")
    expect(hints.last?.rect == .init(x:236.0/320,y:49.0/640,width:7.0/320,height:1.0/640),"Dense dots retain the exact original prefix boundary")
    expect(Set(hints.map(\.id)).count==24 && hints.allSatisfy{$0.source=="local_visual"},"Dense glyph hints remain unique pixel evidence without identity authority")
}
expect(more([(270,49,5,5),(279,49,5,5),(287,50,4,4)]).count==1,"A third dot exactly -1.5 from equal spacing remains included")
expect(more([(270,49,5,5),(279,49,5,5),(290,50,4,4)]).count==1,"A third dot exactly +1.5 from equal spacing remains included")
expect(more([(270,49,5,5),(279,49,5,5),(286,49,5,5)]).isEmpty,"A third dot below the spacing tolerance remains rejected")
expect(more([(270,49,5,5),(279,49,5,5),(290,49,5,5)]).isEmpty,"A third dot above the spacing tolerance remains rejected")
expect(more([(269,50,3,3),(288,50,4,4),(307,50,5,5)]).count==1,"The larger third dot, rather than the first pair, sets the valid maximum spacing")
expect(more([(270,49,5,5),(279,51,4,4),(290,51,4,4)]).isEmpty,"The first two dots on different rows cannot form a More control")
print("Visual controls: \(checks) production raster/glyph checks passed; drawn fixture pixels, no device UI acceptance")
