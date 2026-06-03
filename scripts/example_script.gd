class_name ExampleScript
extends RefCounted

## The hardcoded "block script" for Milestone 1, expressed purely as data.
##
## This is exactly the structure a visual block editor would emit: an Array of
## block dictionaries, each {"opcode": ..., "inputs": ...}, with substacks held
## as nested Arrays under "inputs".
##
## In Scratch-pseudocode it reads:
##
##     when green flag clicked
##     point in direction 55
##     forever
##         move 5 steps
##         if <touching edge?>
##             point in direction (bounce)   # reflect off the edge
##
## The starting direction (55°, a non-45° diagonal) makes the sprite sweep the
## whole stage and bounce off all four walls indefinitely.
static func build() -> Array:
	return [
		{
			"opcode": "when_flag_clicked",
			"inputs": {
				"body": [
					{
						"opcode": "point_in_direction",
						"inputs": {"direction": 55},
					},
					{
						"opcode": "forever",
						"inputs": {
							"body": [
								{
									"opcode": "move_steps",
									"inputs": {"steps": 5},
								},
								{
									"opcode": "if",
									"inputs": {
										"condition": {"opcode": "touching_edge?", "inputs": {}},
										"body": [
											{
												"opcode": "point_in_direction",
												"inputs": {"direction": "bounce"},
											},
										],
									},
								},
							],
						},
					},
				],
			},
		},
	]
