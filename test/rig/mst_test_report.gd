extends RefCounted
class_name MSTTestReport
## Collects timings and claim verdicts, then prints them as one aligned table.
## Everything the rig learns goes through here so the output can be pasted back
## as a single block.


class Claim:
	var id : String
	var text : String
	var verdict : String
	var evidence : String

	func _init(p_id: String, p_text: String, p_verdict: String, p_evidence: String) -> void:
		id = p_id
		text = p_text
		verdict = p_verdict
		evidence = p_evidence


var _timings : Array = []
var _claims : Array = []
var _notes : Array = []


func add_timing(suite: String, phase: String, label: String, msec: float, detail: String = "") -> void:
	_timings.append({
		"suite": suite,
		"phase": phase,
		"label": label,
		"msec": msec,
		"detail": detail,
	})


func add_claim(id: String, text: String, passed: bool, evidence: String) -> void:
	_claims.append(Claim.new(id, text, "HOLDS" if passed else "FAILS", evidence))


func add_inconclusive(id: String, text: String, evidence: String) -> void:
	_claims.append(Claim.new(id, text, "UNCLEAR", evidence))


func add_note(note: String) -> void:
	_notes.append(note)


func print_all() -> void:
	print("")
	print("================================================================================")
	print(" MST CAVE RIG RESULTS")
	print(" Godot %s | %s" % [Engine.get_version_info()["string"], OS.get_name()])
	print("================================================================================")

	print("")
	print(" TIMINGS")
	print(" %-10s %-22s %-30s %10s  %s" % ["suite", "phase", "label", "msec", "detail"])
	print(" " + "-".repeat(94))
	for row in _timings:
		print(" %-10s %-22s %-30s %10.2f  %s" % [
			row["suite"], row["phase"], row["label"], row["msec"], row["detail"]
		])

	print("")
	print(" CLAIMS")
	print(" " + "-".repeat(94))
	for claim: Claim in _claims:
		print(" [%-7s] %s" % [claim.verdict, claim.text])
		print("           %s" % claim.evidence)

	if not _notes.is_empty():
		print("")
		print(" NOTES")
		print(" " + "-".repeat(94))
		for note in _notes:
			print(" - %s" % note)

	print("")
	print("================================================================================")
	print("")
