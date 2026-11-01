//
//  UnavailableEngineStub.swift
//  Lume
//
//  Stands in for an engine this platform never links, so a stray attempt
//  moves straight on to the host's failure handling.
//

import SwiftUI

struct UnavailableEngineStub: View {
    let onUnavailable: () -> Void

    var body: some View {
        Color.black
            .onAppear(perform: onUnavailable)
    }
}
