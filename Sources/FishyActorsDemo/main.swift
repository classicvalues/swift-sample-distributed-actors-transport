//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-sample-distributed-actors-transport open source project
//
// Copyright (c) 2021 Apple Inc. and the swift-sample-distributed-actors-transport project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of swift-sample-distributed-actors-transport project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed

import FishyActorTransport
import ArgumentParser
import Logging

import func Foundation.sleep
import struct Foundation.Data
import class Foundation.JSONDecoder
import NIOFoundationCompat

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Define Distributed Actors

distributed actor ChatRoom {
  let topic: String
  var chatters: Set<Chatter>

  init(topic: String, transport: ActorTransport) {
    defer { transport.actorReady(self) } // TODO(distributed): will be synthesized

    self.topic = topic
    self.chatters = []
  }

  distributed func join(chatter: Chatter) async -> String {
    let newChatter = chatters.insert(chatter).inserted
    print("[\(self.simpleID)] Chatter [\(chatter.simpleID)] joined this chat room (about '\(topic)'")

    // not a new member, let's greet it appropriately
    guard newChatter else {
      return "Welcome back to the '\(topic)' chat room! (chatters: \(chatters.count))"
    }

    Task {
      // no need to await for this task, we want to send back the greeting first
      // and then the details about the chatters in the room will be sent.
      for other in chatters where chatter != other {
        try await chatter.chatterJoined(room: self, chatter: other)
      }
    }

    return "Welcome to the '\(topic)' chat room! (chatters: \(chatters.count))"
  }

  distributed func leave(chatter: Chatter) {
    print("[\(self.simpleID)] chatter left the room: \(chatter)")
    chatters.remove(chatter)

    // TODO: notify the others
  }

}

distributed actor Chatter {
  var rooms: [ChatRoom: Set<Chatter>] = [:]

  init(transport: ActorTransport) {
    defer { transport.actorReady(self) } // FIXME(distributed): this will be synthesized
  }

  distributed func join(room: ChatRoom) async throws {
    // join the chat-room
    let welcomeMessage = try await room.join(chatter: self)

    // seems we joined successfully, might as well just add ourselfs right away
    rooms[room, default: []].insert(self)

    print("[\(self.simpleID)] \(welcomeMessage)")
  }

  // Every chat room we're in will keep us posted about chatters joining the room.
  // This way we can notice when our friend joined the room and send them a direct message etc.
  distributed func chatterJoined(room: ChatRoom, chatter: Chatter) {
    guard chatter != self else {
      // we shouldn't be getting such message, but even if we did, we can ignore
      // the information that we joined the room, because we already know this
      // from the return value from the room.join call.
      return
    }

    rooms[room, default: []].insert(chatter)
    print("[\(self.simpleID)] Chatter [\(chatter.simpleID)] joined [\(room.simpleID)] " +
          "(total known members in room \(rooms[room]?.count ?? 0) (including self))")
  }

  distributed func chatRoomMessage(_ message: String, from chatter: Chatter) {
    print("[\(self.simpleID)]] \(chatter.simpleID) wrote: \(message)")
  }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Make some chatters and start chatting!

struct Demo: ParsableCommand {
  @Flag(help: "Interactive mode")
  var interactive: Bool = false

  @Flag(help: "Log level used by (all) ActorTransport instancs")
  var transportLogLevel: Logger.Level = .warning

  mutating func run() throws {
    LoggingSystem.bootstrap(PrettyDemoLogHandler.init)

    var keepAlive: Set<Chatter> = []

    // one node to keep the chat rooms:
    let roomNode = try FishyTransport(host: "127.0.0.1", port: 8001, logLevel: transportLogLevel)
    // multiple nodes for the regional chatters:
    let firstNode = try FishyTransport(host: "127.0.0.1", port: 9002, logLevel: transportLogLevel)
    let secondNode = try FishyTransport(host: "127.0.0.1", port: 9003, logLevel: transportLogLevel)

    let room = ChatRoom(topic: "Cute Capybaras", transport: roomNode)

    let alice = Chatter(transport: firstNode)
    let bob = Chatter(transport: secondNode)
    let charlie = Chatter(transport: secondNode)

    for chatter in [alice, bob, charlie] {
      keepAlive.insert(chatter)

      Task {
        // we resolve a reference to `room` using our `p.actorTransport`
        // since all chatters are on other nodes than the chat room,
        // this will always yield a remote reference.
        let remoteRoom = try ChatRoom.resolve(room.id, using: chatter.actorTransport)
        try await chatter.join(room: remoteRoom)
      }
    }

    // normally transports will ofer `await .park()` functions, but for now just sleep:
    sleep(1000)
    _ = keepAlive
  }
}

if #available(macOS 12.0, /* Linux */ *) {
  Demo.main()
} else {
  fatalError("Unsupported platform")
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Support

// Make logger level codable to use it as option in the Argument Parser main struct.
extension Logger.Level: Codable, EnumerableFlag {}

extension ChatRoom: CustomStringConvertible {
  nonisolated var description: String {
    "\(Self.self)(\(id))"
  }

  // Simple ID representation for nice to read log printouts in the demo.
  // Only useful for printing and human operator interaction, not guaranteed to be unique. 
  nonisolated var simpleID: String {
    guard let identity = self.id.underlying as? FishyIdentity else {
      return String(describing: self.id)
    }
    let idPrefix = identity.id.prefix { $0 != "-" }
    return ":\(identity.port)/\(identity.typeName)@\(idPrefix)-..."
  }
}

extension Chatter: CustomStringConvertible {
  nonisolated var description: String {
    "\(Self.self)(\(id))"
  }

  // Simple ID representation for nice to read log printouts in the demo.
  // Only useful for printing and human operator interaction, not guaranteed to be unique. 
  nonisolated var simpleID: String {
    guard let identity = self.id.underlying as? FishyIdentity else {
      return String(describing: self.id)
    }
    let idPrefix = identity.id.prefix { $0 != "-" }
    return ":\(identity.port)/\(identity.typeName)@\(idPrefix)-..."
  }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Transport specific _remote implementations
//       These would be source generated via a SwiftPM plugin in a real impl

extension ChatRoom: MessageRecipient {

  enum _Message: Sendable, Codable {
    case join(chatter: Chatter)
    // TODO: normally also offer: case _unknown
  }

  // TODO: needs
  nonisolated func _receiveAny<Encoder, Decoder>(
    envelope: Envelope, encoder: Encoder, decoder: Decoder
  ) async throws -> Encoder.Output where Encoder: TopLevelEncoder, Decoder: TopLevelDecoder {
    let message = try decoder.decode(_Message.self, from: envelope.message as! Decoder.Input) // TODO: this would have to be restructured to avoid the as!
    return try await self._receive(message: message, encoder: encoder)
  }

  nonisolated func _receive<Encoder>(
    message: _Message, encoder: Encoder
  ) async throws -> Encoder.Output where Encoder: TopLevelEncoder {
    do {
      switch message {
      case .join(let chatter):
        let response = try await self.join(chatter: chatter)
        return try encoder.encode(response)
      }
    } catch {
      fatalError("Error handling not implemented; \(error)")
    }
  }

  @_dynamicReplacement (for :_remote_join(chatter:))
  nonisolated func _fishy_join(chatter: Chatter) async throws -> String {
    let fishy = self.requireFishyTransport
    let message = Self._Message.join(chatter: chatter)
    return try await fishy.send(message, to: self.id, expecting: String.self)
  }
}

extension Chatter: MessageRecipient {
  enum _Message: Sendable, Codable {
    case join(room: ChatRoom)
    case chatRoomMessage(message: String, chatter: Chatter)
    case chatterJoined(room: ChatRoom, chatter: Chatter)
    // TODO: normally also offer: case _unknown
  }

  nonisolated func _receiveAny<Encoder, Decoder>(
    envelope: Envelope, encoder: Encoder, decoder: Decoder
  ) async throws -> Encoder.Output
    where Encoder: TopLevelEncoder, Decoder: TopLevelDecoder {
    let message = try decoder.decode(_Message.self, from: envelope.message as! Decoder.Input) // TODO: this needs restructuring to avoid the cast, we need to know what types we work with
    return try await self._receive(message: message, encoder: encoder)
  }

  nonisolated func _receive<Encoder>(
    message: _Message, encoder: Encoder
  ) async throws -> Encoder.Output where Encoder: TopLevelEncoder {
    switch message {
    case .join(let room):
      try await self.join(room: room)
      return try encoder.encode(Optional<String>.none)

    case .chatRoomMessage(let message, let chatter):
      try await self.chatRoomMessage(message, from: chatter)
      return try encoder.encode(Optional<String>.none)

    case .chatterJoined(let room, let chatter):
      try await self.chatterJoined(room: room, chatter: chatter)
      return try encoder.encode(Optional<String>.none)
    }
  }

  @_dynamicReplacement (for :_remote_join(room:))
  nonisolated func _fishy_join(room: ChatRoom) async throws {
    let fishy = self.requireFishyTransport
    let message = Self._Message.join(room: room)
    // TODO: sadly source gen has to specialize for the void return here
    // if we made it possible to pass Void.self we could always return
    // whatever send has returned here.
    _ = try await fishy.send(message, to: self.id, expecting: NoResponse.self)
  }

  @_dynamicReplacement (for :_remote_chatterJoined(room:chatter:))
  nonisolated func _fishy_chatterJoined(room: ChatRoom, chatter: Chatter) async throws {
    let fishy = self.requireFishyTransport
    let message = Self._Message.chatterJoined(room: room, chatter: chatter)
    // TODO: sadly source gen has to specialize for the void return here
    // if we made it possible to pass Void.self we could always return
    // whatever send has returned here.
    _ = try await fishy.send(message, to: self.id, expecting: NoResponse.self)
  }

  @_dynamicReplacement (for :_remote_chatRoomMessage(_:from:))
  nonisolated func _fishy_chatRoomMessage(_ message: String, from chatter: Chatter) async throws {
    let fishy = self.requireFishyTransport
    let message = Self._Message.chatRoomMessage(message: message, chatter: chatter)
    // TODO: sadly source gen has to specialize for the void return here
    // if we made it possible to pass Void.self we could always return
    // whatever send has returned here.
    _ = try await fishy.send(message, to: self.id, expecting: NoResponse.self)
  }
}

extension DistributedActor {
  nonisolated var requireFishyTransport: FishyTransport {
    guard let fishy = actorTransport as? FishyTransport else {
      fatalError("""
                 'Generated' \(#function) not compatible with underlying transport.
                 Expected \(FishyTransport.self) but got: \(type(of: self.actorTransport))
                 """)
    }

    return fishy
  }
}