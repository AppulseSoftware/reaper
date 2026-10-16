// Renders Reaper's app icon. Usage: swiftc -o /tmp/makeicon Icon/MakeIcon.swift && /tmp/makeicon out.png [preview.png]
import AppKit
import SwiftUI

struct Tombstone: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 322, y: 780))
        p.addLine(to: CGPoint(x: 322, y: 450))
        p.addArc(center: CGPoint(x: 512, y: 450), radius: 190, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: 702, y: 780))
        p.closeSubpath()
        return p
    }
}

struct Hill: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 60, y: 790))
        p.addQuadCurve(to: CGPoint(x: 964, y: 770), control: CGPoint(x: 540, y: 690))
        p.addLine(to: CGPoint(x: 964, y: 964))
        p.addLine(to: CGPoint(x: 60, y: 964))
        p.closeSubpath()
        return p
    }
}

struct AppIcon: View {
    let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous)

    var body: some View {
        ZStack {
            // Dusk sky
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.45, blue: 0.27), Color(red: 0.45, green: 0.10, blue: 0.30), Color(red: 0.10, green: 0.05, blue: 0.16)],
                startPoint: .init(x: 0.5, y: 0.1), endPoint: .init(x: 0.5, y: 0.9))

            // Moon
            Circle().fill(Color(red: 1.0, green: 0.93, blue: 0.80).opacity(0.9))
                .frame(width: 150, height: 150)
                .position(x: 700, y: 270)
                .shadow(color: .white.opacity(0.5), radius: 30)

            // Tombstone with engraved prompt
            Tombstone().fill(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.45)],
                                            startPoint: .top, endPoint: .bottom))
            Tombstone().stroke(.black.opacity(0.25), lineWidth: 6)
            // Carved prompt: a lighter floor shifted down inside the glyph leaves a shadowed upper wall.
            // Flattened then masked so nothing bleeds outside the letters.
            let prompt = Text(">_").font(.system(size: 150, weight: .black, design: .monospaced))
            ZStack {
                prompt.foregroundStyle(Color(white: 0.16))
                prompt.foregroundStyle(Color(white: 0.34)).offset(y: 7).blur(radius: 4)
            }
            .compositingGroup()
            .mask(prompt.foregroundStyle(.black))
            .position(x: 512, y: 560)

            // Hill in front
            Hill().fill(LinearGradient(colors: [Color(red: 0.12, green: 0.05, blue: 0.14), Color(red: 0.05, green: 0.02, blue: 0.07)],
                                       startPoint: .top, endPoint: .bottom))
        }
        .frame(width: 1024, height: 1024)
        .clipShape(squircle.inset(by: 100))
        .overlay(squircle.inset(by: 100).strokeBorder(.white.opacity(0.08), lineWidth: 3))
        // Flatten first: otherwise the icon's drop shadow is applied to every layer, including the prompt.
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .frame(width: 1024, height: 1024)
    }
}

struct Preview: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            ForEach([360.0, 128.0, 64.0, 32.0, 16.0], id: \.self) { s in
                AppIcon().scaleEffect(s / 1024).frame(width: s, height: s)
            }
        }
        .padding(30)
        .background(Color(white: 0.93))
    }
}

@MainActor
func write<V: View>(_ view: V, to path: String, scale: CGFloat) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    write(AppIcon(), to: args[1], scale: 1)
    if args.count > 2 { write(Preview(), to: args[2], scale: 2) }
}
