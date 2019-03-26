//
//  HiveMindProcess.swift
//  App
//
//  Created by Joseph Roque on 2019-03-17.
//

import Foundation
import HiveEngine
import Vapor

enum HiveMindError: Error {
	case notInitialized
	case invalidOutput
	case invalidMovement
	case stringToDataConversion
	case JSONExtraction
	case unknown
}

class HiveMindProcess {

	/// Location of the HiveMind executable
	private var executable: URL {
		return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
			.appendingPathComponent("..")
			.appendingPathComponent("hive-engine")
			.appendingPathComponent(".build")
			.appendingPathComponent("release")
			.appendingPathComponent("HiveMind")
	}

	private let process = Process()

	private let processInput = Pipe()
	private let processOutput = Pipe()

	init(isFirst: Bool) throws {
		process.executableURL = executable
		process.standardInput = processInput
		process.standardOutput = processOutput
		try process.run()

		guard let writeData = "new \(isFirst)\n".data(using: .utf8) else {
			throw HiveMindError.stringToDataConversion
		}

		processInput.fileHandleForWriting.write(writeData)
		print("(PID \(process.processIdentifier)): Initialized HiveMindProcess")
	}

	deinit {
		close()
	}

	/// Ask for a `Movement` from the HiveMind.
	///
	/// - Parameters:
	///   - req: the server request made
	func play(req: Request) -> Future<Movement> {
		print("(PID \(process.processIdentifier)): Playing move")
		let movementPromise = req.eventLoop.newPromise(of: Movement.self)

		// Write the command to the process
		guard let writeData = "play\n".data(using: .utf8) else {
			movementPromise.fail(error: HiveMindError.stringToDataConversion)
			return movementPromise.futureResult
		}

		processInput.fileHandleForWriting.write(writeData)

		// FIXME: 12 seconds should be a configuration for the HiveMind, rather than a constant in each project
		DispatchQueue.global().asyncAfter(deadline: .now() + 12) { [weak self] in
			guard let self = self else {
				print("`self` was nil after waiting for move")
				movementPromise.fail(error: HiveMindError.unknown)
				return
			}

			let readData = self.processOutput.fileHandleForReading.availableData

			guard let cleanData = self.extractJSON(from: readData) else {
				if let stringData = String(data: readData, encoding: .utf8) {
					print("Failed data: `\(stringData)`")
				}
				movementPromise.fail(error: HiveMindError.JSONExtraction)
				return
			}

			let decoder = JSONDecoder()
			do {
				let move = try decoder.decode(Movement.self, from: cleanData)
				movementPromise.succeed(result: move)
			} catch {
				if let stringData = String(data: cleanData, encoding: .utf8) {
					print("Failed data: `\(stringData)`")
				}
				movementPromise.fail(error: error)
			}
		}

		return movementPromise.futureResult
	}

	/// Forward a `Movement` to the HiveMind.
	///
	/// - Parameters:
	///   - move: the movement to apply, which should be valid in the HiveMind's current state.
	///           If the movement is not valid, the HiveMind process will fail silently.
	func apply(move: Movement) {
		print("(PID \(process.processIdentifier)): Applying move `\(move)`")
		let encoder = JSONEncoder()
		guard let data = try? encoder.encode(move), let moveString = String(data: data, encoding: .utf8) else {
			print("Failed to convert \(move) to JSON")
			return
		}

		let writeableValue = "move \(moveString)\n"
		guard let writeData = writeableValue.data(using: .utf8) else {
			print("Failed to convert \(writeableValue) to Data")
			return
		}

		processInput.fileHandleForWriting.write(writeData)
	}

	/// Close the current HiveMind process.
	func close() {
		if process.isRunning {
			process.terminate()
			print("(PID \(process.processIdentifier)): Terminated HiveMindProcess")
		}
	}

	/// Given `Data` representing a `String`, extracts the first JSON object to appear in the `String`
	/// and returns it as `Data`
	///
	/// - Parameters:
	///   - data: the data to parse
	private func extractJSON(from data: Data) -> Data? {
		guard let dataAsString = String(data: data, encoding: .utf8),
			let startIndex = dataAsString.firstIndex(of: "{") else { return nil }
		var endIndex = dataAsString.index(after: startIndex)
		var depth = 1
		while depth > 0 && endIndex != dataAsString.endIndex {
			switch dataAsString[endIndex] {
			case "{": depth += 1
			case "}": depth -= 1
			default:
				// Does nothing
				break
			}
			endIndex = dataAsString.index(after: endIndex)
		}

		return dataAsString[startIndex..<endIndex].data(using: .utf8)
	}
}
