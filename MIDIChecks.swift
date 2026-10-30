import Foundation
import Combine

@main struct MIDITest {
 @MainActor static func main() async {
  if CommandLine.arguments.contains("--benchmark") { benchmark(); return }
  #if !MIDI_BASELINE
  if CommandLine.arguments.contains("--queued-benchmark") { await queuedBenchmark(); return }
  #endif
  let midi = MIDIController(connectHardware: false, persistMappings: false)
  var events: [(String, Double)] = []
  midi.onAction = { events.append(($0, $1)) }
  func expect(_ action: String, _ value: Double, _ label: String) {
   guard let last = events.last, last.0 == action, abs(last.1 - value) < 0.00001 else { fatalError("FAIL \(label): \(events)") }
  }
  midi.inject(bytes: [0xB0,16,124,0,127]); expect("deck0.high",1,"14-bit endpoint")
  midi.inject(bytes: [0xB0,17]); midi.inject(bytes: [0,1,64]); expect("deck0.mid",8192.0/16380,"packet-spanning running status")
  let beforePlay = events.count
  midi.inject(bytes: [0x90,34,127,34,0]); expect("deck0.play",1,"play note-on")
  precondition(events.count == beforePlay + 1,"release must not toggle play")
  midi.inject(bytes: [0xB0,64,1]); expect("deck0.jog",1,"CW")
  midi.inject(bytes: [64,127]); expect("deck0.jog",-1,"CCW")
  let reserved = events.count; midi.inject(bytes:[64,64,64,0]); precondition(events.count == reserved)
  midi.inject(bytes:[0x90,52,127,32,127]); expect("deck0.beatjump",-1,"shift beatjump")
  midi.inject(bytes:[34,127]); expect("deck0.sync",1,"shift play sync")
  midi.inject(bytes:[52,0])
  midi.inject(bytes:[0x90,35,127,38,127,35,0]); expect("deck0.cue",1,"duplicate cue OR")
  midi.inject(bytes:[38,0]); expect("deck0.cue",0,"last cue release")
  let sysexBefore = events.count
  midi.inject(bytes:[0xF0,1,64,127,0xF7,64,1]); precondition(events.count == sysexBefore)
  midi.inject(bytes:[0xB0,64,0xF8,1]); expect("deck0.jog",1,"realtime interleaving")
  let missingHeartbeat = events.count
  midi.inject(bytes:[0xB0,32,63],source:"YaSushi Jog MIDI"); precondition(events.count == missingHeartbeat)
  midi.inject(bytes:[0xB0,33,1,0x90,64,127],source:"YaSushi Jog MIDI"); expect("deck0.touch",1,"jog press heartbeat")
  midi.inject(bytes:[0xB0,32,63],source:"YaSushi Jog MIDI"); expect("deck0.jog",63.0/64,"AS5600 count scale")
  try? await Task.sleep(nanoseconds:510_000_000)
  midi.inject(bytes:[0xB0,32,1],source:"YaSushi Jog MIDI"); expect("deck0.touch",0,"stale heartbeat releases held wheel")
  midi.inject(bytes:[0xB1,33,1,0x91,64,127],source:"YaSushi Jog MIDI"); expect("deck1.touch",1,"channel2")
  midi.inject(bytes:[0x81,64,0],source:"YaSushi Jog MIDI"); expect("deck1.touch",0,"real note off")
  midi.learn(action:"deck2.volume")
  midi.inject(bytes:[0xB3,7,64],source:"Generic Controller"); precondition(!midi.isLearning)
  midi.inject(bytes:[0xB3,7,127],source:"Generic Controller"); expect("deck2.volume",1,"generic learn")
  let data = try! JSONEncoder().encode(midi.mappings)
  precondition(try! JSONDecoder().decode([MIDIMapping].self,from:data) == midi.mappings)
  midi.simulate(action:"deck3.hotcue8",value:1); expect("deck3.hotcue8",1,"test simulation")
  print("PASS: 18 MIDI assertions; 14-bit pair, running status, buttons, quadrature, reserved values, modifiers, cue OR, SysEx/realtime, watchdog, both decks, learn, Codable, simulation.")
  #if !MIDI_BASELINE
  await queuedChecks()
  #endif
  let inventory = MIDIController(persistMappings:false)
  print("CoreMIDI sources: \(inventory.sources)")
 }
 @MainActor static func benchmark() {
  var results: [[String: Any]] = []
  let cycles = 30_000
  for profile in ["paired14", "jog-notes", "mixed-running-status"] {
   let midi = MIDIController(connectHardware: false, persistMappings: false)
   var callbacks = 0, notifications = 0
   var checksum = 0.0
   midi.onAction = { _, value in callbacks += 1; checksum += value }
   let observer = midi.objectWillChange.sink { notifications += 1 }
   let start = ProcessInfo.processInfo.systemUptime
   let minimumDuration = CommandLine.arguments.contains("--sustained") ? 1.5 : 0
   var totalCycles = 0
   repeat {
   for i in 0..<cycles {
    let value = (i * 17) % 16381
    switch profile {
    case "paired14":
     midi.inject(bytes:[0xB0,16,UInt8(value & 127),0,UInt8(value >> 7)])
    case "jog-notes":
     midi.inject(bytes:[0xB0,64,1,64,127,0x90,55,127,55,0])
    default:
     midi.inject(bytes:[0xB0,16,UInt8(value & 127),0,UInt8(value >> 7),64,1,64,127,0x90,55,127,55,0])
    }
   }
   totalCycles += cycles
   } while ProcessInfo.processInfo.systemUptime-start < minimumDuration
   let seconds = ProcessInfo.processInfo.systemUptime - start
   let messages = totalCycles * (profile == "paired14" ? 2 : profile == "jog-notes" ? 4 : 6)
   results.append(["profile":profile,"cycles":totalCycles,"midi_messages":messages,"action_callbacks":callbacks,"seconds":seconds,"messages_per_second":Double(messages)/seconds,"observable_notifications":notifications,"callback_checksum":checksum])
   withExtendedLifetime(observer) {}
  }
  let output: [String: Any] = ["schema":1,"build":"swiftc -O -swift-version 5","hardware_input":false,"benchmark_kind":"synchronous raw-byte injection with a Combine objectWillChange subscriber; no audio or UI rendering","results":results]
  let data = try! JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
  if let arg = CommandLine.arguments.first(where:{$0.hasPrefix("--output=")}) {
   try! data.write(to:URL(fileURLWithPath:String(arg.dropFirst(9))))
  }
  print(String(data:data,encoding:.utf8)!)
 }

 #if !MIDI_BASELINE
 @MainActor static func queuedChecks() async {
  let midi = MIDIController(connectHardware:false,persistMappings:false)
  var events: [(String,Double)] = []
  midi.onAction = { events.append(($0,$1)) }
  midi.enqueueForTesting(bytes:[0xB0,33,1,0x90,64,127],source:"YaSushi Jog MIDI",receivedAt:ProcessInfo.processInfo.systemUptime-2)
  await midi.waitForPendingInput()
  precondition(events.isEmpty,"queued stale heartbeat must not arm a touch")
  midi.enqueueForTesting(bytes:[0xB0,33,1,0x90,64,127,0x80,64,0],source:"YaSushi Jog MIDI")
  await midi.waitForPendingInput()
  precondition(events.count == 2 && events[0].0 == "deck0.touch" && events[0].1 == 1 && events[1].1 == 0)
  midi.learn(action:"deck2.volume")
  midi.inject(bytes:[0xB3,7,64,7,127],source:"Generic Controller")
  precondition(events.last!.0 == "deck2.volume" && events.last!.1 == 1,"learn must invalidate route inside a packet")
  // Drain splits oversized packets without dropping a partial MIDI message.
  let split = MIDIController(connectHardware:false,persistMappings:false)
  var turns = 0
  split.onAction = { action,value in if action == "deck0.jog" && value == 1 { turns += 1 } }
  var bytes: [UInt8] = [0xB0]
  for _ in 0..<10_000 { bytes.append(contentsOf:[64,1]) }
  split.enqueueForTesting(bytes:bytes)
  await split.waitForPendingInput()
  precondition(turns == 10_000)
  precondition(split.performanceStatistics["maximum_drain_bytes"]! <= 8192)
  // Throttling must eventually publish the terminal event, even when input stops.
  midi.simulate(action:"before-final",value:0)
  midi.inject(bytes:[0xB3,7,0],source:"Generic Controller")
  try? await Task.sleep(nanoseconds:70_000_000)
  precondition(midi.lastMessage.contains("deck2.volume") && midi.lastMessage.contains("0.000"))
  print("PASS: queued stale-arrival heartbeat, fresh touch edges, in-packet Learn invalidation, oversized packet split, diagnostic terminal flush.")
 }

 @MainActor static func queuedBenchmark() async {
  let midi = MIDIController(connectHardware:false,persistMappings:false)
  let cycles = 30_000
  var callbacks = 0, notifications = 0, ordered = true, checksum = 0.0
  var terminal: [String:Double] = [:]
  var pulses = 0, maximumPulseGap = 0.0, previousPulse = ProcessInfo.processInfo.systemUptime
  midi.onAction = { action,value in
   let cycle = callbacks / 5
   let position = callbacks % 5
   let expectedAction = ["deck0.high","deck0.jog","deck0.jog","deck0.touch","deck0.touch"][position]
   let expectedValue = position == 0 ? Double((cycle * 17) % 16381)/16380 : [0,1,-1,1,0][position]
   if action != expectedAction || abs(value-expectedValue)>0.00001 { ordered = false }
   callbacks += 1; checksum += value; terminal[action] = value
  }
  let observer = midi.objectWillChange.sink { notifications += 1 }
  let pulse = Task { @MainActor in
   while !Task.isCancelled {
    do { try await Task.sleep(nanoseconds:1_000_000) } catch { return }
    let now = ProcessInfo.processInfo.systemUptime
    maximumPulseGap = max(maximumPulseGap,now-previousPulse); previousPulse = now; pulses += 1
   }
  }
  let start = ProcessInfo.processInfo.systemUptime
  await Task.detached {
   for i in 0..<cycles {
    let value = (i * 17) % 16381
    midi.enqueueForTesting(bytes:[0xB0,16,UInt8(value & 127),0,UInt8(value >> 7),64,1,64,127,0x90,55,127,55,0])
   }
  }.value
  await midi.waitForPendingInput()
  let seconds = ProcessInfo.processInfo.systemUptime-start
  pulse.cancel()
  // Include delayed terminal publication in notification accounting.
  try? await Task.sleep(nanoseconds:70_000_000)
  precondition(ordered && callbacks == cycles*5,"FIFO must preserve every relative and note edge")
  precondition(terminal["deck0.touch"] == 0 && terminal["deck0.jog"] == -1)
  precondition(abs(terminal["deck0.high"]!-Double(((cycles-1)*17)%16381)/16380)<0.00001)
  let output: [String:Any] = ["schema":1,"hardware_input":false,"benchmark_kind":"background producer through the real callback FIFO; MainActor dispatch and concurrent 1 ms scheduling probe; no audio or visual UI rendering","midi_messages":cycles*6,"action_callbacks":callbacks,"callback_checksum":checksum,"seconds":seconds,"messages_per_second":Double(cycles*6)/seconds,"callback_order_exact":ordered,"terminal_values":terminal,"observable_notifications_including_terminal_flush":notifications,"concurrent_main_actor_probe_pulses":pulses,"maximum_probe_gap_seconds":maximumPulseGap,"statistics":midi.performanceStatistics]
  let data = try! JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
  if let arg = CommandLine.arguments.first(where:{$0.hasPrefix("--output=")}) { try! data.write(to:URL(fileURLWithPath:String(arg.dropFirst(9)))) }
  print(String(data:data,encoding:.utf8)!)
  withExtendedLifetime(observer) {}
 }

 #endif
}
