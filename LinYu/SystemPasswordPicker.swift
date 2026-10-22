import AuthenticationServices
import SwiftUI

@MainActor
final class SystemPasswordPicker: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var completion: ((String, String) -> Void)?
    private var controller: ASAuthorizationController?
    private var window: UIWindow?
    func choose(completion: @escaping (String, String) -> Void) {
        guard controller == nil,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        self.window = window
        self.completion = completion
        let controller = ASAuthorizationController(authorizationRequests: [ASAuthorizationPasswordProvider().createRequest()])
        self.controller = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window! }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASPasswordCredential { completion?(credential.user, credential.password) }
        finish()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { finish() }
    private func finish() { controller = nil; window = nil; completion = nil }
}
