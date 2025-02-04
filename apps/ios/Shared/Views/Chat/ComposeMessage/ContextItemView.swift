//
//  ContextItemView.swift
//  SimpleX
//
//  Created by JRoberts on 13/03/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//

import SwiftUI
import SimpleXChat

struct ContextItemView: View {
    @Environment(\.colorScheme) var colorScheme
    let contextItem: ChatItem
    let contextIcon: String
    let cancelContextItem: () -> Void

    var body: some View {
        HStack {
            Image(systemName: contextIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundColor(.secondary)
            MsgContentView(
                text: contextItem.text,
                formattedText: contextItem.formattedText,
                sender: contextItem.memberDisplayName
            )
            .lineLimit(3)
            Spacer()
            Button {
                withAnimation {
                    cancelContextItem()
                }
            } label: {
                Image(systemName: "multiply")
            }
        }
        .padding(12)
        .frame(minHeight: 50)
        .frame(maxWidth: .infinity)
        .background(chatItemFrameColor(contextItem, colorScheme))
        .padding(.top, 8)
    }
}

struct ContextItemView_Previews: PreviewProvider {
    static var previews: some View {
        let contextItem: ChatItem = ChatItem.getSample(1, .directSnd, .now, "hello")
        return ContextItemView(contextItem: contextItem, contextIcon: "pencil.circle", cancelContextItem: {})
    }
}
