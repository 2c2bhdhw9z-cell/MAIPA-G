import Foundation

/// A tarball shaped like GitHub's: one top folder, a PAX global comment with the commit id,
/// a long path (PAX), a binary file, an empty file, a symlink, a Unicode path, and an entry that
/// tries to escape the folder. Made with Python's tarfile module.
enum Fixtures {
    static let sampleTarball = Data(base64Encoded: """
H4sIAAAAAAACA+2ZT07bQBjFvbbEBboa0U27wH/GY7tdIFoJWrpoi2j30WB/gRHjGcseCByBo3TVQ3CxOkmlCtKAkBwHkffbxBlZ
iqI377357CAMwg9H8uqQZEmNtxKiOcs+oygT/66n63EU58Jjp94AXLRONt3Pe5tJyllhq4qM25UnRcwTkWb5u/fRA198D7wYbOHs
TkO13fkrcrga/+dputz/3XUsUi7yPBJz/+dp4rEU/l+D/scHH/e/HgRV2av+mRAP5v9d/TlPuMci6L9yXrPv3Q7w/UPS2rKJbXQZ
+D+osKZkWhliE+XO2E97ToYp06qSAuT/i/Z/2xQ9d8DT8z9OBUf+r0//SioTtBM1dsPkf3xP/yQVMfJ/CFRV28axT/bClNIpa3xN
jrlZ3u+y7W5TbPt1o4x7M1t7i/B/WQTPYP5P4oX5n8fd+f8K/l85PBKslu5s9/9FcEnN9UhbczoaW91tkJGRFY2GXQ1Lolpfh4Za
R2U4VppG01PpSM7vnd4UuCuHaOqt//uV8tH+59nd/k/iLInQ/0NgiEpN3WjHJJvKNQsDOGmD/S/bllwbantqg9r08Qz+Mf8nyf35
L8njHP4fgpujb5+3/FdTx299Odw/hiM23f9U1e56ep7q9fz/YP8vPP/hmUD/r0l/rcz5zmxRlhWtR38xe//D+38VAf2f4fwfdWJj
/l8PIlk2/hdyfPsrNPL29yXG6w3K/073vU72vbnqg+Q/Xzj/J5lA/w/y940qbEmzEGD2HCbftP4PQmoLWVOvJ/4n+n9h/u/6H/4f
hPbMXuiSGbqkhp0QmzTKOTLIAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAB45vwBTYDLgwBQAAA=
""", options: .ignoreUnknownCharacters)!
}
