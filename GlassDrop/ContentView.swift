import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        if model.phase == .streaming {
            StreamView()
        } else {
            ConnectView()
        }
    }
}

// MARK: 연결 화면

struct ConnectView: View {
    @EnvironmentObject var model: SessionModel
    @State private var host = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            List {
                if let note = model.bluetoothNote {
                    Section { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if let err = model.errorText {
                    Section { Label(err, systemImage: "xmark.octagon").foregroundStyle(.red) }
                }

                if model.phase == .connecting {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(model.status)
                        }
                        Button("취소", role: .cancel) { model.disconnect() }
                    }
                } else {
                    Section("근처 노트북") {
                        if model.devices.isEmpty {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("노트북을 찾는 중이에요. 노트북에서 Glass Drop을 켜 두세요.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.devices) { d in
                            Button {
                                model.connect(to: d.id)
                            } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer")
                                    Text(d.name)
                                    Spacer()
                                    Text("연결").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    Section {
                        TextField("노트북 주소 (예: 192.168.0.5)", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                        TextField("열쇠 (영문·숫자 32글자)", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("주소로 연결") { model.connectManual(host: host, token: token) }
                            .disabled(host.isEmpty)
                    } header: {
                        Text("주소로 직접 연결")
                    } footer: {
                        Text("블루투스 없이 연결하는 방법이에요. 이 방법은 클립보드와 마우스·키보드 공유를 쓸 수 없어요.")
                    }
                }
            }
            .navigationTitle("Glass Drop")
            .onAppear { model.startScan() }
        }
    }
}

// MARK: 화면 받는 중

struct StreamView: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurfaceView(surface: model.surface)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.showControls.toggle() }

            if !model.hasFirstFrame {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(model.status).foregroundStyle(.white).multilineTextAlignment(.center)
                }
                .padding()
            }

            if model.showControls || !model.hasFirstFrame {
                VStack {
                    ControlsCard()
                    Spacer()
                }
                .padding()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

struct ControlsCard: View {
    @EnvironmentObject var model: SessionModel

    private var sensitivity: Binding<Double> {
        Binding(get: { Double(model.sharing.sensitivity) },
                set: { model.sharing.sensitivity = UInt8(min(30, max(4, $0.rounded()))) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.laptopName.isEmpty ? "연결됨" : "연결됨 · \(model.laptopName)").font(.headline)
                Spacer()
                Button("끊기", role: .destructive) { model.disconnect() }
                    .buttonStyle(.borderedProminent)
            }

            if let side = model.pointerSide {
                Text(side.onTablet ? "마우스 포인터가 이 기기 쪽에 있어요." : "마우스 포인터가 노트북에 있어요.")
                    .font(.footnote)
            }

            if model.bleLinked {
                Toggle("마우스·키보드 공유", isOn: Binding(
                    get: { model.sharing.has(SharingState.mouse) },
                    set: { model.setShare(SharingState.mouse, $0) }))
                Toggle("노트북 → 이 기기 클립보드", isOn: Binding(
                    get: { model.sharing.has(SharingState.clipToTablet) },
                    set: { model.setShare(SharingState.clipToTablet, $0) }))
                Toggle("이 기기 → 노트북 클립보드", isOn: Binding(
                    get: { model.sharing.has(SharingState.clipFromTablet) },
                    set: { model.setShare(SharingState.clipFromTablet, $0) }))
                HStack {
                    Text("포인터 속도")
                    Slider(value: sensitivity, in: 4...30, step: 1) { editing in
                        if !editing { model.pushSharing() }
                    }
                }
                HStack {
                    Button("노트북 클립보드 가져오기") { Task { await model.pullClipboard() } }
                    Button("내 클립보드 보내기") { Task { await model.pushClipboard() } }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            } else {
                Text("블루투스 없이 연결해서 클립보드·공유는 쓸 수 없어요.").font(.footnote)
            }

            if let note = model.clipNote {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            Text("마우스·키보드는 노트북이 블루투스로 직접 이 기기에 보내요. 화면을 눌러도 노트북으로 전달되지 않아요.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 520)
    }
}
