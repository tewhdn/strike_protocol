class_name StrikeTcpClient
extends Node

signal state_changed(state: String)
signal message_received(message: Dictionary)
signal protocol_error(message: String)

const MAX_PACKET_BYTES := 1024 * 1024
const CONNECT_TIMEOUT_SECONDS := 8.0
const HEARTBEAT_SECONDS := 5.0

var _peer := StreamPeerTCP.new()
var _state := "offline"
var _rx_buffer := ""
var _connect_elapsed := 0.0
var _heartbeat_elapsed := 0.0
var _last_status := StreamPeerTCP.STATUS_NONE
var _outbox: Array[Dictionary] = []


func connect_to_server(host: String, port: int) -> Error:
	close()
	_peer = StreamPeerTCP.new()
	_peer.set_no_delay(true)
	var error := _peer.connect_to_host(host.strip_edges(), port)
	if error != OK:
		_set_state("error")
		protocol_error.emit("Connection could not start (error %d)." % error)
		return error
	_connect_elapsed = 0.0
	_heartbeat_elapsed = 0.0
	_last_status = StreamPeerTCP.STATUS_CONNECTING
	_set_state("connecting")
	return OK


func close() -> void:
	if _peer.get_status() != StreamPeerTCP.STATUS_NONE:
		_peer.disconnect_from_host()
	_rx_buffer = ""
	_outbox.clear()
	_last_status = StreamPeerTCP.STATUS_NONE
	_set_state("offline")


func is_connected_to_server() -> bool:
	return _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func send_packet(message: Dictionary, queue_while_connecting: bool = false) -> Error:
	if not is_connected_to_server():
		if queue_while_connecting and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTING:
			_outbox.append(message.duplicate(true))
			return OK
		return ERR_UNCONFIGURED
	var line := JSON.stringify(message) + "\n"
	var data := line.to_utf8_buffer()
	if data.size() > MAX_PACKET_BYTES:
		protocol_error.emit("Outgoing packet exceeds the 1 MiB limit.")
		return ERR_OUT_OF_MEMORY
	return _peer.put_data(data)


func _process(delta: float) -> void:
	_peer.poll()
	var status := _peer.get_status()
	if status != _last_status:
		_on_status_changed(status)
		_last_status = status

	if status == StreamPeerTCP.STATUS_CONNECTING:
		_connect_elapsed += delta
		if _connect_elapsed >= CONNECT_TIMEOUT_SECONDS:
			protocol_error.emit("Connection timed out.")
			close()
		return

	if status != StreamPeerTCP.STATUS_CONNECTED:
		return

	_heartbeat_elapsed += delta
	if _heartbeat_elapsed >= HEARTBEAT_SECONDS:
		_heartbeat_elapsed = 0.0
		send_packet({"type": "ping", "ts": Time.get_ticks_msec()})

	_read_available_data()


func _on_status_changed(status: int) -> void:
	match status:
		StreamPeerTCP.STATUS_CONNECTED:
			_set_state("connected")
			for packet in _outbox:
				send_packet(packet)
			_outbox.clear()
		StreamPeerTCP.STATUS_CONNECTING:
			_set_state("connecting")
		StreamPeerTCP.STATUS_ERROR:
			_set_state("error")
			protocol_error.emit("The TCP connection failed.")
		StreamPeerTCP.STATUS_NONE:
			_set_state("offline")


func _read_available_data() -> void:
	while _peer.get_available_bytes() > 0:
		var count := mini(_peer.get_available_bytes(), 65536)
		var result: Array = _peer.get_partial_data(count)
		if result.size() < 2 or result[0] != OK:
			protocol_error.emit("Failed to read TCP data.")
			return
		var bytes: PackedByteArray = result[1]
		_rx_buffer += bytes.get_string_from_utf8()
		if _rx_buffer.length() > MAX_PACKET_BYTES:
			protocol_error.emit("Incoming TCP frame exceeded the 1 MiB limit.")
			_rx_buffer = ""
			return

	var newline := _rx_buffer.find("\n")
	while newline >= 0:
		var line := _rx_buffer.substr(0, newline).strip_edges()
		_rx_buffer = _rx_buffer.substr(newline + 1)
		if not line.is_empty():
			_parse_line(line)
		newline = _rx_buffer.find("\n")


func _parse_line(line: String) -> void:
	var parsed = JSON.parse_string(line)
	if parsed == null or not (parsed is Dictionary):
		protocol_error.emit("Server sent malformed JSON.")
		return
	message_received.emit(parsed)


func _set_state(next_state: String) -> void:
	if _state == next_state:
		return
	_state = next_state
	state_changed.emit(_state)
