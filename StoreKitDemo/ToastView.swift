//
//  ToastView.swift
//  StoreKitDemo
//
//  Created by Codex.
//

import SwiftUI

struct ToastData: Identifiable {
    let id = UUID()
    let message: String
    let style: ToastStyle
}

enum ToastStyle {
    case loading
    case success
    case failure
    case info
    
    var icon: String {
        switch self {
        case .loading: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    var tint: Color {
        switch self {
        case .loading: return Color.blue
        case .success: return Color.green
        case .failure: return Color.red
        case .info: return Color.orange
        }
    }
}

struct ToastView: View {
    let toast: ToastData?
    
    @ViewBuilder
    var body: some View {
        if let toast {
            HStack(spacing: 12) {
                if toast.style == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: toast.style.icon)
                        .foregroundColor(.white)
                }
                Text(toast.message)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 15)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [toast.style.tint.opacity(0.92), toast.style.tint.opacity(0.75)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
            )
            .shadow(color: toast.style.tint.opacity(0.28), radius: 14, x: 0, y: 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
