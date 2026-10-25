import Foundation

struct PhoneRasterPixel { var red: Double; var green: Double; var blue: Double; var alpha: Double }
struct PhoneRasterImage {
    let width: Int
    let height: Int
    let rgba: [UInt8]
    var valid: Bool { width > 0 && height > 0 && width <= 1024 && height <= 2048 && rgba.count == width * height * 4 }
    func sample(_ x: Double, _ y: Double) -> PhoneRasterPixel? {
        guard valid, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        let offset = (min(height - 1, Int(y * Double(height))) * width + min(width - 1, Int(x * Double(width)))) * 4
        return .init(red: Double(rgba[offset])/255, green: Double(rgba[offset+1])/255,
                     blue: Double(rgba[offset+2])/255, alpha: Double(rgba[offset+3])/255)
    }
}

/// Current-image geometric hints. These are not app/recipient identities. A
/// domain must independently identify the page before using a detected control.
enum PhoneVisualControls {
    private struct Component {
        var x0: Int; var y0: Int; var x1: Int; var y1: Int; var points: [(Int, Int)]
        var w: Int { x1-x0+1 }; var h: Int { y1-y0+1 }
        var cx: Double { Double(x0+x1)/2 }; var cy: Double { Double(y0+y1)/2 }
    }
    static func detect(in image: PhoneRasterImage) -> [PhoneUIElement] {
        guard image.valid, image.width >= 120, image.height >= 180 else { return [] }
        let w=image.width, h=image.height
        var found: [(String, Component)] = []
        for (side, bounds) in [(0,(0.01,0.025,0.21,0.19)),(1,(0.72,0.025,0.99,0.20)),(2,(0.78,0.55,0.99,0.98))] {
            // The public result is the first 24 detections. Later regions
            // cannot affect that exact prefix or its final de-duplication.
            if found.count >= 24 { break }
            let x0=Int(bounds.0*Double(w)), y0=Int(bounds.1*Double(h)), x1=Int(bounds.2*Double(w)), y1=Int(bounds.3*Double(h))
            var samples:[Double]=[]
            for y in stride(from:y0,through:y1,by:3) { for x in stride(from:x0,through:x1,by:3) { samples.append(luma(image,x,y)) } }
            samples.sort(); guard let bg=samples.dropFirst(samples.count/2).first else { continue }
            func ink(_ x:Int,_ y:Int)->Bool { let v=luma(image,x,y); return bg>0.5 ? v < bg-0.35 : v > bg+0.35 }
            var visited=Set<Int>(), components:[Component]=[]
            for y in y0...y1 { for x in x0...x1 {
                let key=y*w+x
                guard !visited.contains(key), ink(x,y) else { continue }
                var queue=[(x,y)], index=0, c=Component(x0:x,y0:y,x1:x,y1:y,points:[])
                visited.insert(key)
                while index<queue.count {
                    let (a,b)=queue[index];index+=1;c.points.append((a,b));c.x0=min(c.x0,a);c.x1=max(c.x1,a);c.y0=min(c.y0,b);c.y1=max(c.y1,b)
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx=a+dx,ny=b+dy,k=ny*w+nx
                        if nx>=x0 && nx<=x1 && ny>=y0 && ny<=y1 && !visited.contains(k) && ink(nx,ny) { visited.insert(k);queue.append((nx,ny)) }
                    }}
                }
                if c.points.count<=2000 { components.append(c) }
            }}
            if side==0 {
                for c in components where c.h>=8 && c.h<=Int(Double(h)*0.065) && c.w>=4 {
                    let ratio=Double(c.h)/Double(c.w)
                    if (1.35...3.2).contains(ratio), Double(c.points.count)/Double(c.w*c.h)<0.65,
                       fit(c,{ x,y in abs(x-abs(2*y-1))<0.24 })>0.84,
                       c.points.contains(where:{ abs(Double($0.1-c.y0)/Double(max(1,c.h-1))-0.5)<0.14 && $0.0<c.x0+c.w/3 }) {
                        found.append(("视觉:返回",c))
                    } else if c.w>=8 && (0.75...1.3).contains(ratio),
                              fit(c,{ x,y in min(abs(x-y),abs(x+y-1))<0.18 })>0.89,
                              c.points.count>c.w*2 && Double(c.points.count)/Double(c.w*c.h)<0.6 {
                        found.append(("视觉:关闭",c))
                    }
                }
            }
            if side==1 {
                let dots=components.filter { $0.w<=max(5,w/60) && $0.h<=max(5,w/60) && abs($0.w-$0.h)<=1 && Double($0.points.count)/Double($0.w*$0.h)>0.55 }.sorted{$0.cx<$1.cx}
                if dots.count>=3 {
                  let maximumDiameter = Double(dots.reduce(0) { max($0, $1.w) })
                  func firstDot(at x:Double, afterEqual:Bool=false)->Int {
                    var lower=0, upper=dots.count
                    while lower<upper {
                        let middle=lower+(upper-lower)/2, value=dots[middle].cx
                        if value<x || (afterEqual && value==x) {lower=middle+1} else {upper=middle}
                    }
                    return lower
                  }
                  dotSearch: for i in 0..<(dots.count-2) { for j in (i+1)..<(dots.count-1) {
                    let a=dots[i], b=dots[j], d1=b.cx-a.cx
                    // Necessary parts of the original three-dot predicate.
                    // Sorted centres let us stop beyond any possible diameter.
                    if d1>maximumDiameter*4.5 {break}
                    guard abs(a.cy-b.cy)<=1.2, abs(a.h-b.h)<=1,
                          d1>=Double(max(a.w,b.w))*1.4 else {continue}
                    let expected=b.cx+d1
                    let lower=max(j+1,firstDot(at:expected-1.5)), upper=firstDot(at:expected+1.5,afterEqual:true)
                    guard lower<upper else {continue}
                    // Pixel component centres are exact half-integers. This
                    // inclusive range is exactly abs(d1-d2)<=1.5; keep the full
                    // predicate below and preserve the old i/j/k output order.
                    for k in lower..<upper {
                    let c=dots[k],d2=c.cx-b.cx,diam=Double(max(a.w,max(b.w,c.w)))
                    guard abs(a.cy-b.cy)<=1.2,abs(b.cy-c.cy)<=1.2,abs(d1-d2)<=1.5,
                          d1>=diam*1.4,d1<=diam*4.5,c.x1-a.x0<Int(Double(w)*0.14),
                          abs(a.h-b.h)<=1,abs(b.h-c.h)<=1 else { continue }
                    found.append(("视觉:更多",Component(x0:a.x0,y0:min(a.y0,min(b.y0,c.y0)),x1:c.x1,y1:max(a.y1,max(b.y1,c.y1)),points:a.points+b.points+c.points)))
                    if found.count>=24 {break dotSearch}
                  }}}
                }
            }
            if side==2 {
                for c in components where c.w>=10 && c.h>=10 && c.w<=Int(Double(w)*0.12) && c.h<=Int(Double(w)*0.12) && abs(c.w-c.h)<=3 {
                    let cx=Double(c.x0+c.x1)/2,cy=Double(c.y0+c.y1)/2,r=Double(c.w+c.h)/4
                    var total=0,good=0,ring=Set<Int>(),cross=Set<Int>(),badInner=0,inner=0
                    for y in c.y0...c.y1 { for x in c.x0...c.x1 {
                        let dx=(Double(x)-cx)/r,dy=(Double(y)-cy)/r,dist=hypot(dx,dy)
                        if ink(x,y) {
                            total+=1
                            if abs(dist-0.94)<0.18 || (abs(dx)<0.17 && abs(dy)<0.62) || (abs(dy)<0.17 && abs(dx)<0.62) { good+=1 }
                            if abs(dist-0.94)<0.18 { ring.insert(Int((atan2(dy,dx)+Double.pi)/(2*Double.pi)*12)%12) }
                            if abs(dx)<0.17 && dy>0.25 && dy<0.62 { cross.insert(0) }
                            if abs(dx)<0.17 && dy < -0.25 && dy > -0.62 { cross.insert(1) }
                            if abs(dy)<0.17 && dx>0.25 && dx<0.62 { cross.insert(2) }
                            if abs(dy)<0.17 && dx < -0.25 && dx > -0.62 { cross.insert(3) }
                        }
                        if abs(dx)>0.25 && abs(dx)<0.55 && abs(dy)>0.25 && abs(dy)<0.55 { inner+=1; if ink(x,y){badInner+=1} }
                    }}
                    if total>16 && Double(good)/Double(total)>0.88 && ring.count>=11 && cross.count==4 && inner>0 && Double(badInner)/Double(inner)<0.15 {
                        found.append(("视觉:添加",c))
                    }
                }
            }
        }
        var seen=Set<String>()
        return found.prefix(24).compactMap { label,c in
            let id="visual.\(label).\(c.x0).\(c.y0).\(c.w).\(c.h)"
            guard seen.insert(id).inserted else { return nil }
            return .init(id:id,label:label,rect:.init(x:Double(c.x0)/Double(w),y:Double(c.y0)/Double(h),width:Double(c.w)/Double(w),height:Double(c.h)/Double(h)),source:"local_visual")
        }
    }
    private static func luma(_ image:PhoneRasterImage,_ x:Int,_ y:Int)->Double {
        let i=(y*image.width+x)*4
        return (0.2126*Double(image.rgba[i])+0.7152*Double(image.rgba[i+1])+0.0722*Double(image.rgba[i+2]))/255
    }
    private static func fit(_ c:Component,_ predicate:(Double,Double)->Bool)->Double {
        Double(c.points.filter { predicate(Double($0.0-c.x0)/Double(max(1,c.w-1)),Double($0.1-c.y0)/Double(max(1,c.h-1))) }.count)/Double(c.points.count)
    }
}
