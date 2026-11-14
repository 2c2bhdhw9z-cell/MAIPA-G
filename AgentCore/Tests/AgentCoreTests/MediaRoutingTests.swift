import Testing
@testable import AgentCore

/// Owner, 14 November 2026: a screenshot with a short message in the Korg-Bot chat counted as a
/// picture request, so the reply ran on the phone at Low thinking and stopped ("The AI sent nothing
/// for 14 minutes") when he left the app. In a chat working on a repo, only an explicit ask for a
/// picture or video stays on the phone.
@Suite("Screenshots in a repo chat are not picture requests")
struct MediaRoutingTests {
    @Test("His screenshot messages go to the computer at full thinking")
    func screenshotsInRepoChats() {
        for message in [
            "iM gOiNg tO mAkE oNe cOoRdInAtEd eDiT nOw dUgHghhhhHhhH iM mEnTaLlY rEtArDeD",
            "Why the fuck do you keep reading and editing runtime/ui.js and tests/plugins.test.mjs",
            "fix this",
            "Updated. Try Now.",
            "the background service crashes, look at the image",
            "change the button colour like in the picture",
        ] {
            #expect(!MediaRequest.wanted(message, hasImageAttachments: true, chatHasPictures: true, workingOnRepo: true), "\(message)")
        }
    }

    @Test("Asking for a picture or video still makes one, in any chat")
    func explicitAsks() {
        for message in [
            "make a picture of a fox in the snow",
            "generate an image of the Korg logo",
            "draw a cat",
            "turn this photo into a video",
            "upscale it",
            QuickPictureRequest.redoText,
            QuickPictureRequest.editPrefix + "make the sky purple",
        ] {
            #expect(MediaRequest.wanted(message, hasImageAttachments: true, chatHasPictures: true, workingOnRepo: true), "\(message)")
        }
    }

    @Test("A chat without a repo keeps the quick picture edits")
    func pictureChatsUnchanged() {
        #expect(MediaRequest.wanted("make it black", hasImageAttachments: true))
        #expect(MediaRequest.wanted("I want the white to be black and the black to be white", hasImageAttachments: true))
        #expect(MediaRequest.wanted("make it bluer", hasImageAttachments: false, chatHasPictures: true))
    }
}
