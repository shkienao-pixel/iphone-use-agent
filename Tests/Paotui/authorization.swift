import Foundation
import CryptoKit

@main struct AuthorizationChecks {
    static var checks=0
    static func expect(_ value:Bool,_ label:String){checks+=1;precondition(value,label)}
    @MainActor static func main() async throws {
        var requests:[URLRequest]=[]
        var payload:[String:Any]=["authCode":"fixture-code","shortLink":"https://dpurl.cn/fixture"]
        var status=200
        var redirected=false
        let client=MeituanPaotuiAuthorization(transport:{ request in
            requests.append(request)
            return (try JSONSerialization.data(withJSONObject:["code":0,"data":payload]),HTTPURLResponse(url:redirected ? URL(string:"https://evil.test/")! : request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
        })
        let session=try await client.start()
        let parts=URLComponents(url:requests[0].url!,resolvingAgainstBaseURL:false)!
        let query=Dictionary(uniqueKeysWithValues:parts.queryItems!.map{($0.name,$0.value!)})
        expect(parts.host=="passport.meituan.com" && parts.path=="/api/account/userauth/code","Pinned Passport service")
        expect(query["client_id"]==MeituanPaotuiAuthorization.clientID,"Pinned client ID")
        let challenge=SHA256.hash(data:Data(session.verifier.utf8)).map{String(format:"%02x",$0)}.joined()
        expect(session.verifier.count==64 && query["code_challenge"]==challenge,"Exact provider hex PKCE")
        expect(requests[0].value(forHTTPHeaderField:"cli-version")=="1.0.5","Access-token capable authorization version")
        expect(session.link.absoluteString=="https://dpurl.cn/fixture" && session.expires.timeIntervalSinceNow>590,"Short-lived official link")
        payload=["authStatus":1]
        expect(try await client.finish(session)==nil,"Pending authorization cannot become a credential")
        payload=["authStatus":4,"authMode":1,"accessToken":"fixture-credential"]
        expect(try await client.finish(session)=="fixture-credential","Confirmed grant yields credential only to host")
        let finishParts=URLComponents(url:requests.last!.url!,resolvingAgainstBaseURL:false)!
        let finish=Dictionary(uniqueKeysWithValues:finishParts.queryItems!.map{($0.name,$0.value!)})
        expect(finish["code_verifier"]==session.verifier && finish["auth_code"]=="fixture-code","Authorization bound to same PKCE session")
        for authStatus in [2,3] {
            payload=["authStatus":authStatus]
            do {_=try await client.finish(session);fatalError("Canceled authorization accepted")}catch{checks+=1}
        }
        payload=["authStatus":4,"authMode":0,"token":"fixture-legacy-token"]
        do {_=try await client.finish(session);fatalError("Unsupported grant silently accepted")}catch{checks+=1}
        let expired=MeituanPaotuiAuthorization.Session(code:"fixture",verifier:"fixture",link:session.link,expires:.distantPast)
        do {_=try await client.finish(expired);fatalError("Expired session accepted")}catch{checks+=1}
        payload=["authCode":"fixture-code","shortLink":"https://meituan.com.evil.test/fixture"]
        do {_=try await client.start();fatalError("Untrusted authorization URL accepted")}catch{checks+=1}
        redirected=true
        do {_=try await client.start();fatalError("Redirected auth response accepted")}catch{checks+=1}
        redirected=false;status=401
        do {_=try await client.start();fatalError("Failed HTTP accepted")}catch{checks+=1}
        print("PASS: \(checks) native Passport PKCE, confirmation, cancel, expiry and URL checks; offline only")
    }
}
