import AVFoundation
import SwiftUI

@main
struct YapperApp: App
{
  @State private var model = AppModel()

  var body: some Scene
  {
    WindowGroup
    {
      Group
      {
        if model.loggedIn
        {
          ServerView()
        }
        else
        {
          ConnectView()
        }
      }
      .environment(model)
    }
  }
}

struct ConnectView: View
{
  @Environment(AppModel.self) private var model

  var body: some View
  {
    @Bindable var model = model

    NavigationStack
    {
      Form
      {
        Section
        {
          TextField("host or host:port", text: $model.address)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("Name", text: $model.username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Password (if the server has one)", text: $model.password)
            .textContentType(.password)
        }
        footer:
        {
          Text("Everything between you and the server is encrypted.")
        }

        Section
        {
          Button
          {
            model.connect()
          }
          label:
          {
            HStack
            {
              Text(model.connecting ? "Connecting…" : "Connect")
              Spacer()
              if model.connecting
              {
                ProgressView()
              }
            }
          }
          .disabled(model.connecting)

          if model.connecting
          {
            Button("Cancel", role: .destructive) { model.disconnect() }
          }
        }

        if !model.errorText.isEmpty
        {
          Section
          {
            Label(model.errorText, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Yapper")
      .onSubmit { model.connect() }
      .task
      {
        // Ask up front, so the prompt doesn't land in the middle of joining a call
        _ = await AVAudioApplication.requestRecordPermission()
      }
    }
  }
}

struct ServerView: View
{
  @Environment(AppModel.self) private var model

  var body: some View
  {
    TabView
    {
      NavigationStack { ChannelsView().callToolbar() }
        .tabItem { Label("Channels", systemImage: "person.3.fill") }

      NavigationStack { ChatView().callToolbar() }
        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
    }
    .fullScreenCover(isPresented: Binding(get: { model.viewer != nil }, set: { if !$0 { model.stopWatching() } }))
    {
      ScreenView()
    }
  }
}

struct CallToolbar: ViewModifier
{
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View
  {
    @Bindable var model = model

    content
      .navigationTitle(model.status?.serverName ?? "")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar
      {
        ToolbarItem(placement: .topBarLeading)
        {
          Button("Leave", role: .destructive) { model.disconnect() }
            .tint(.red)
        }
        ToolbarItemGroup(placement: .topBarTrailing)
        {
          Toggle(isOn: $model.muted)
          {
            Label("Mute", systemImage: model.muted ? "mic.slash.fill" : "mic.fill")
          }
          Toggle(isOn: $model.deafened)
          {
            Label("Deafen", systemImage: model.deafened ? "speaker.slash.fill" : "speaker.wave.2.fill")
          }
        }
      }
      .toggleStyle(.button)
  }
}

extension View
{
  func callToolbar() -> some View
  {
    modifier(CallToolbar())
  }
}

struct ChannelsView: View
{
  @Environment(AppModel.self) private var model

  var body: some View
  {
    let status = model.status ?? ConnectionStatus()

    List
    {
      if !model.audioError.isEmpty
      {
        Section
        {
          Label(model.audioError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }

      ForEach(status.channels)
      { channel in
        Section
        {
          Button
          {
            model.join(channel.id)
          }
          label:
          {
            HStack
            {
              Label(channel.name, systemImage: "number")
                .foregroundStyle(.primary)
              Spacer()
              if channel.id == model.myChannel
              {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
              }
            }
          }

          ForEach(status.users.filter { $0.channel == channel.id })
          { user in
            UserRow(user: user, canWatch: user.sharing && user.id != status.sessionId && user.channel == model.myChannel)
          }
        }
      }
    }
  }
}

struct UserRow: View
{
  @Environment(AppModel.self) private var model

  let user: User
  let canWatch: Bool

  var body: some View
  {
    HStack
    {
      // Redraws often enough for the talking light to follow the voice packets
      TimelineView(.periodic(from: .now, by: 0.1))
      { _ in
        let talking = model.isTalking(user.id)
        Image(systemName: talking ? "waveform.circle.fill" : "person.circle.fill")
          .font(.title2)
          .foregroundStyle(talking ? .green : .secondary)
          .contentTransition(.symbolEffect(.replace))
      }

      Text(user.name)

      Spacer()

      if canWatch
      {
        Button("Watch", systemImage: "play.rectangle.fill") { model.startWatching(user.id) }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
      else if user.sharing
      {
        Image(systemName: "rectangle.inset.filled.on.rectangle")
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, 12)
  }
}

struct ChatView: View
{
  @Environment(AppModel.self) private var model
  @State private var draft = ""

  var body: some View
  {
    let chat = model.status?.chat ?? []

    VStack(spacing: 0)
    {
      ScrollViewReader
      { proxy in
        ScrollView
        {
          LazyVStack(spacing: 6)
          {
            ForEach(chat)
            { line in
              ChatBubble(line: line, mine: line.from == model.username)
                .id(line.id)
            }
          }
          .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: chat.last?.id)
        {
          withAnimation { proxy.scrollTo(chat.last?.id, anchor: .bottom) }
        }
        .overlay
        {
          if chat.isEmpty
          {
            ContentUnavailableView("No messages", systemImage: "bubble.left.and.bubble.right", description: Text("Messages go to everyone in your channel."))
          }
        }
      }

      HStack(spacing: 8)
      {
        TextField("Message", text: $draft)
          .textFieldStyle(.plain)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(Capsule().strokeBorder(.quaternary))
          .submitLabel(.send)
          .onSubmit(send)

        Button(action: send)
        {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title)
        }
        .disabled(draft.isEmpty)
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.bar)
    }
  }

  private func send()
  {
    guard !draft.isEmpty else
    {
      return
    }
    model.sendChat(draft)
    draft = ""
  }
}

struct ChatBubble: View
{
  let line: ChatLine
  let mine: Bool

  var body: some View
  {
    VStack(alignment: mine ? .trailing : .leading, spacing: 2)
    {
      if !mine
      {
        Text(line.from)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
      }
      Text(line.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(mine ? .white : .primary)
        .background(mine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }
    .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
  }
}

struct ScreenView: View
{
  @Environment(AppModel.self) private var model

  var body: some View
  {
    let name = model.status?.users.first { $0.id == model.watching }?.name ?? "Someone"

    ZStack
    {
      Color.black.ignoresSafeArea()

      // Shows until the first frame covers it
      ProgressView("Waiting for the picture…")
        .tint(.white)
        .foregroundStyle(.white)

      if let viewer = model.viewer
      {
        VideoView(layer: viewer.layer)
          .ignoresSafeArea()
      }
    }
    .overlay(alignment: .topLeading)
    {
      HStack
      {
        Text("\(name)'s screen")
          .font(.headline)
        Spacer()
        Button("Close", systemImage: "xmark.circle.fill") { model.stopWatching() }
          .labelStyle(.iconOnly)
          .font(.title)
          .symbolRenderingMode(.hierarchical)
      }
      .foregroundStyle(.white)
      .padding()
    }
    .statusBarHidden()
  }
}
