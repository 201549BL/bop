"""Render the onboarding tutorial and its still image from the desk bobblehead.

Run from the repository root with Blender 5.2 and ffmpeg on PATH:
    blender -b "Artwork/Bop Desk Bobblehead.blend" --python-exit-code 1 -P Artwork/render_onboarding.py

Append `-- --dark` to render the dark appearance.
"""

from array import array
from math import radians, sin
from pathlib import Path
import subprocess
import sys
import tempfile

import bpy
from mathutils import Matrix, Vector


FPS = 24
LAST_FRAME = 114
NOD_PEAKS = (61, 75, 89)


def aim(object_, target):
    direction = Vector(target) - object_.location
    object_.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def set_stage(scene, dark):
    camera = scene.camera
    camera.location = (-6.5, -8.1, 4.2)
    aim(camera, (0, -0.29, 1.77))
    camera.data.ortho_scale = 7.85
    camera.data.shift_x = 0.085

    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, -0.015))
    floor = bpy.context.object
    floor.name = "Charcoal studio" if dark else "Ivory studio"
    material = bpy.data.materials.new(floor.name)
    shader = material.node_tree.nodes.get("Principled BSDF")
    backdrop = (0.022, 0.025, 0.033, 1) if dark else (0.73, 0.68, 0.59, 1)
    shader.inputs["Base Color"].default_value = backdrop
    shader.inputs["Roughness"].default_value = 0.84
    shader.inputs["Emission Color"].default_value = backdrop
    shader.inputs["Emission Strength"].default_value = 0.65 if dark else 1.28
    floor.data.materials.append(material)

    scene.render.film_transparent = False
    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.taa_render_samples = 32
    scene.render.resolution_x = 960
    scene.render.resolution_y = 508
    scene.render.resolution_percentage = 100
    scene.render.fps = FPS
    scene.frame_start = 1
    scene.frame_end = LAST_FRAME


def animate_head(head, spring):
    # Looking down at the keys, briefly up and to the side, then down to the pad.
    poses = [
        (1, 3, 0, -4),
        (7, 4, -1, -3),
        (14, 2, 0, -3),
        (20, -6, -3, -20),
        (26, -8, -4, -25),
        (32, -4, -3, -17),
        (40, 5, 1, 3),
        (47, 5, 1, 5),
        (51, 4, 1, 3),
        (54, 1, 0, 1),
        (56, -5, -1, 0),
    ]
    first, second, third = NOD_PEAKS
    poses.extend([
        (first - 2, 8, 0, 1),
        (first, 21, 2, 3),
        (first + 3, 10, 2, 3),
        (first + 7, -6, -1, 0),
        (second - 3, 3, -2, -1),
        (second, 17, -2, -2),
        (second + 2, 12, -1, -1),
        (second + 7, -8, 1, 2),
        (third - 3, 1, 2, 4),
        (third, 24, 3, 5),
        (third + 3, 14, 2, 3),
        (third + 8, -7, -2, -3),
        (third + 13, 4, 1, 0),
        (third + 19, 0, 0, -2),
        (LAST_FRAME, 2, 0, -2),
    ])

    # Flex the coil as its top follows the head, keeping the lower mount planted.
    coil = spring.children[0]
    rest = coil.shape_key_add(name="Rest")
    bend_x = coil.shape_key_add(name="Flex across desk")
    bend_y = coil.shape_key_add(name="Flex toward desk")
    for index, vertex in enumerate(rest.data):
        weight = smoothstep(0.0, 0.24, vertex.co.z)
        bend_x.data[index].co.x += 0.1 * weight
        bend_y.data[index].co.y += 0.1 * weight
    for shape in (bend_x, bend_y):
        shape.slider_min = -1

    initial_location = head.location.copy()
    coil_height = initial_location.z - spring.location.z
    head.rotation_mode = "XYZ"
    for frame, pitch, roll, yaw in poses:
        head.rotation_euler = tuple(map(radians, (pitch, roll, yaw)))
        lean = sin(radians(pitch))
        sway = sin(radians(roll))
        shift = Vector((0.32 * sway, -0.18 * lean, -0.10 * lean))
        head.location = initial_location + shift
        spring.scale.z = 1 + shift.z / coil_height
        bend_x.value = shift.x / 0.1
        bend_y.value = shift.y / 0.1
        head.keyframe_insert(data_path="location", frame=frame)
        head.keyframe_insert(data_path="rotation_euler", frame=frame)
        spring.keyframe_insert(data_path="scale", index=2, frame=frame)
        bend_x.keyframe_insert(data_path="value", frame=frame)
        bend_y.keyframe_insert(data_path="value", frame=frame)


def smoothstep(start, end, value):
    t = min(1, max(0, (value - start) / (end - start)))
    return t * t * (3 - 2 * t)


def texture_warmth(mesh):
    texture = mesh.materials[0].node_tree.nodes["Image Texture"].image.copy()
    texture.scale(1024, 1024)
    width, height = texture.size
    pixels = array("f", [0.0]) * (width * height * 4)
    texture.pixels.foreach_get(pixels)
    bpy.data.images.remove(texture)

    warmth = [0.0] * len(mesh.vertices)
    for loop, sample in zip(mesh.loops, mesh.uv_layers.active.data):
        u, v = sample.uv
        x = min(width - 1, max(0, int(u * width)))
        y = min(height - 1, max(0, int(v * height)))
        offset = (y * width + x) * 4
        warmth[loop.vertex_index] = pixels[offset] - pixels[offset + 2]
    return warmth


def animate_hands(body):
    # The scan is one mesh. Use color and position together to distinguish the
    # hand from the keyboard where the two surfaces meet.
    basis = body.shape_key_add(name="Rest")
    near_type = body.shape_key_add(name="Near hand • type")
    far_type = body.shape_key_add(name="Far hand • type")
    reach = body.shape_key_add(name="Near hand • trackpad")
    lift = body.shape_key_add(name="Near hand • lift")
    swipe = body.shape_key_add(name="Near hand • swipe")
    inverse_basis = body.matrix_world.to_3x3().inverted()
    near_keys = Vector((-0.18, -0.71, 1.15))
    far_keys = Vector((0.14, -0.70, 1.17))
    near_tap = Matrix.Rotation(radians(30), 3, "X")
    far_tap = Matrix.Rotation(radians(25), 3, "X")
    warmth = texture_warmth(body.data)

    for index, vertex in enumerate(basis.data):
        point = body.matrix_world @ vertex.co
        x, y, z = point
        skin = smoothstep(0.17, 0.38, warmth[index]) * smoothstep(1.141, 1.165, z)
        sleeve = (1 - smoothstep(-0.11, -0.02, warmth[index])) * smoothstep(1.09, 1.167, z)
        behind_screen = smoothstep(-0.92, -0.76, y)
        near_arm = 1 - smoothstep(-0.13, 0.01, x)
        far_arm = smoothstep(0.015, 0.16, x)
        hand = max(skin, sleeve) * behind_screen
        near_fingers = (1 - smoothstep(-0.51, -0.27, y)) * near_arm * hand
        far_fingers = (1 - smoothstep(-0.49, -0.29, y)) * far_arm * hand
        near_forearm = (1 - smoothstep(-0.50, -0.13, y)) * near_arm * hand
        near_delta = near_tap @ (point - near_keys) + near_keys - point
        far_delta = far_tap @ (point - far_keys) + far_keys - point
        near_type.data[index].co += inverse_basis @ near_delta * near_fingers
        far_type.data[index].co += inverse_basis @ far_delta * far_fingers
        reach.data[index].co += inverse_basis @ Vector((0.06, -0.135, 0.03)) * near_forearm
        lift.data[index].co += inverse_basis @ (near_delta + Vector((-0.045, 0.025, 0.025))) * near_fingers
        swipe.data[index].co += inverse_basis @ Vector((0.115, 0.01, 0.025)) * near_fingers

    for shape, poses in [
        (near_type, [(1, 0), (4, 1), (6, 0), (9, 0.8), (11, 0), (15, 1), (17, 0), (20, 0.78), (22, 0)]),
        (far_type, [(1, 0), (5, 0.9), (8, 0), (11, 0.75), (14, 0), (18, 1), (20, 0), (24, 0.80), (27, 0)]),
        (reach, [(1, 0), (31, 0), (37, 0.25), (41, 1), (50, 1), (56, 0)]),
        (lift, [(1, 0), (32, 0), (37, 1), (41, 0.06), (49, 0.06), (52, 0.65), (57, 0)]),
        (swipe, [(1, 0), (39, 0), (44, 0.78), (46, 1), (49, 0.24), (54, 0)]),
    ]:
        for frame, value in poses:
            shape.value = value
            shape.keyframe_insert(data_path="value", frame=frame)


def render():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    dark = "--dark" in args
    if dark:
        args.remove("--dark")

    scene = bpy.context.scene
    set_stage(scene, dark)
    animate_head(bpy.data.objects["BopHead"], bpy.data.objects["BopSpring"])
    body = bpy.data.objects["Generated body geometry"].children[0]
    animate_hands(body)
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"

    if args:
        output, *frames = args
        for frame in map(int, frames):
            scene.frame_set(frame)
            scene.render.filepath = str(Path(output) / f"{frame:04d}.png")
            bpy.ops.render.render(write_still=True)
        return

    title = "OnboardingTutorialDark" if dark else "OnboardingTutorial"
    resources = Path(__file__).resolve().parent.parent / "Sources/BopApp/Resources"
    output = resources / f"{title}.mp4"
    with tempfile.TemporaryDirectory() as directory:
        scene.render.filepath = f"{directory}/"
        bpy.ops.render.render(animation=True)
        subprocess.run([
            "ffmpeg", "-v", "error", "-y", "-framerate", str(FPS),
            "-i", f"{directory}/%04d.png", "-c:v", "libx264", "-crf", "19",
            "-vf", "scale=out_color_matrix=bt709", "-pix_fmt", "yuv420p",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "iec61966-2-1",
            "-movflags", "+faststart", str(output),
        ], check=True)
    subprocess.run([
        "ffmpeg", "-v", "error", "-y", "-i", str(output), "-frames:v", "1",
        str(resources / f"{title}Poster.png"),
    ], check=True)


if __name__ == "__main__":
    render()
