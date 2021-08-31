//===----------------------------------------------------------------------===//
//
// This source file is part of the fishy-actor-transport open source project
//
// Copyright (c) 2021 Apple Inc. and the fishy-actor-transport project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of fishy-actor-transport project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

final class SourceGen {
  static let header = String(
    """
    // DO NOT MODIFY: This file will be re-generated automatically.
    // Source generated by FishyActorsGenerator (version x.y.z)
    import _Distributed

    import FishyActorTransport
    import ArgumentParser
    import Logging

    import func Foundation.sleep
    import struct Foundation.Data
    import class Foundation.JSONDecoder

    """)

  var targetDirectory: String
  var buckets: Int

  init(targetDirectory: String, buckets: Int) {
    self.targetDirectory = targetDirectory
    self.buckets = buckets

    // TODO: Don't do this in init
    // Just make sure all "buckets" exist
    for i in (0..<buckets) {
      let path = targetFilePath(targetDirectory: targetDirectory, i: i)
      try! SourceGen.header.write(to: path, atomically: true, encoding: .utf8)
    }
  }

  func generate(decl: DistributedActorDecl) -> URL {
    let targetURL = targetFilePath(targetDirectory: targetDirectory, i: 1) // TODO: hardcoded for now, would use bucketing approach to avoid re-generating too many sources

    // TODO: this is hardcoded for the Demo/Sample, but normally we'd analyze the decl and generate the apropriate functions.
    // The synthesis is not very interesting, basically "for each function, make a _impl_ function" and "forward all params to the _Message" etc.
    if (decl.name == "Chatter") {
      try! DEMO_generateChatter(to: targetURL)
    } else if decl.name == "ChatRoom" {
      try! DEMO_generateChatRoom(to: targetURL)
    } else {
      fatalError("SIMPLE SAMPLE/DEMO SOURCE GENERATOR: is not able to handle any distributed actor; This is just an example how these things fit together.")
    }

    // return into which output file the extensions were generated
    return targetURL
  }

  //*************************************************************************************//
  //************************** CAVEAT ***************************************************//
  //** A real implementation would utilize SwiftSyntaxBuilders rather than just String **//
  //** formatting.                                                                     **//
  //** See: https://github.com/apple/swift-syntax/tree/main/Sources/SwiftSyntaxBuilder **//
  //*************************************************************************************//

  private func DEMO_generateChatter(to file: URL) throws {
    var sourceText = ""

    sourceText +=
    """
    extension Chatter: FishyActorTransport.MessageRecipient {
    """
    sourceText += "\n"
    // ==== Generate message representation,
    // In our sample representation we do so by:
    // --- for each distributed function
    // -- emit a `case` that represents the function
    //
    sourceText += """
      enum _Message: Sendable, Codable {
        case join(room: ChatRoom)
        case chatRoomMessage(message: String, chatter: Chatter)
        case chatterJoined(room: ChatRoom, chatter: Chatter)
        // TODO: potentially also create an _unknown(name: String) case?
      }
    """
    sourceText += "\n"
    // ==== Generate the "receive"-side, we must decode the incoming Envelope
    // into a _Message and apply it to our local actor.
    //
    // Some of this code could be pushed out into a transport implementation,
    // specifically the serialization logic does not have to live in here as
    // long as we get hold of the type we need to deserialize.
    sourceText += """
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
      """
    sourceText += "\n"
    sourceText += """
      @_dynamicReplacement (for :_remote_join(room:))
      nonisolated func _fishy_join(room: ChatRoom) async throws {
        let fishy = self.requireFishyTransport
        let message = Self._Message.join(room: room)
        return try await fishy.send(message, to: self.id, expecting: Void.self)
      }
      
      @_dynamicReplacement (for :_remote_chatterJoined(room:chatter:))
      nonisolated func _fishy_chatterJoined(room: ChatRoom, chatter: Chatter) async throws {
        let fishy = self.requireFishyTransport
        let message = Self._Message.chatterJoined(room: room, chatter: chatter)
        return try await fishy.send(message, to: self.id, expecting: Void.self)
      }
      
      @_dynamicReplacement (for :_remote_chatRoomMessage(_:from:))
      nonisolated func _fishy_chatRoomMessage(_ message: String, from chatter: Chatter) async throws {
        let fishy = self.requireFishyTransport
        let message = Self._Message.chatRoomMessage(message: message, chatter: chatter)
        return try await fishy.send(message, to: self.id, expecting: Void.self)
      }
    """
    sourceText += "\n"
    sourceText += """
    }
    """
    sourceText += "\n"
    sourceText += "\n"

    let handle = try FileHandle(forWritingTo: file)
    handle.seekToEndOfFile()
    let textData = sourceText.data(using: .utf8)!
    handle.write(textData)
    try handle.synchronize()
    handle.closeFile()
  }
  
  private func DEMO_generateChatRoom(to file: URL) throws {
    var sourceText = ""

    sourceText +=
    """
    extension ChatRoom: FishyActorTransport.MessageRecipient {
      enum _Message: Sendable, Codable {
        case join(chatter: Chatter)
        case message(message: String, from: Chatter)
        case leave(chatter: Chatter)
        // TODO: normally also offer: case _unknown
      }
      
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
          case .message(let message, let chatter):
            try await self.message(message, from: chatter)
            return try encoder.encode(Optional<String>.none)
          case .leave(let chatter): 
            try await self.leave(chatter: chatter)
            return try encoder.encode(Optional<String>.none)
          }
        } catch {
          fatalError("Error handling not implemented; \\(error)")
        }
      }
      
      @_dynamicReplacement (for :_remote_join(chatter:))
      nonisolated func _fishy_join(chatter: Chatter) async throws -> String {
        let fishy = self.requireFishyTransport
        let message = Self._Message.join(chatter: chatter)
        return try await fishy.send(message, to: self.id, expecting: String.self)
      }

      @_dynamicReplacement (for :_remote_message(_:from:))
      nonisolated func _fishy_message(_ message: String, from chatter: Chatter) async throws {
        let fishy = self.requireFishyTransport
        let message = Self._Message.message(message: message, from: chatter)
        return try await fishy.send(message, to: self.id, expecting: Void.self)
      }

      @_dynamicReplacement (for :_remote_leave(chatter:))
      nonisolated func _fishy_leave(chatter: Chatter) async throws {
        let fishy = self.requireFishyTransport
        let message = Self._Message.leave(chatter: chatter)
        return try await fishy.send(message, to: self.id, expecting: Void.self)
      }
    }


    """

    let handle = try FileHandle(forWritingTo: file)
    handle.seekToEndOfFile()
    let textData = sourceText.data(using: .utf8)!
    handle.write(textData)
    try handle.synchronize()
    handle.closeFile()
  }
  
}
