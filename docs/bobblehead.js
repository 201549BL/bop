import {
  ACESFilmicToneMapping,
  Box3,
  DirectionalLight,
  GLTFLoader,
  Group,
  HemisphereLight,
  OrthographicCamera,
  PMREMGenerator,
  RoomEnvironment,
  Scene,
  Vector3,
  WebGLRenderer,
} from "./vendor/three.js";

const modelUrl = new URL("./assets/bobblehead.glb", import.meta.url);
const viewHeight = 1.15;
const fullTurn = 2 * Math.PI;
const coilBendDistance = 0.18;

export async function loadBobblehead(canvas) {
  const renderer = new WebGLRenderer({ canvas, alpha: true, antialias: true });
  renderer.setClearColor(0x000000, 0);
  renderer.toneMapping = ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1;

  let figure;
  try {
    ({ scene: figure } = await new GLTFLoader().loadAsync(modelUrl.href));
  } catch (error) {
    renderer.dispose();
    throw error;
  }

  const head = figure.getObjectByName("BopHead");
  const spring = figure.getObjectByName("BopSpring");
  if (!head || !spring) {
    renderer.dispose();
    throw new Error("The bobblehead model is missing its head or spring pivot.");
  }

  const neckHeight = head.position.y - spring.position.y;
  const restHead = head.position.clone();
  const restPitch = head.rotation.x;
  const restRoll = head.rotation.z;
  const restYaw = head.rotation.y;
  const restSpringScale = spring.scale.y;
  const flex = addSideBend(spring.getObjectByName("CoilMesh"));
  const motion = {
    pitch: springMotion(10, 0.66),
    roll: springMotion(8, 0.64),
    yaw: springMotion(7, 0.82),
    lift: springMotion(9, 0.6),
  };
  const joints = Object.entries(motion);

  const bounds = new Box3().setFromObject(figure, true);
  const center = bounds.getCenter(new Vector3());
  const scale = 1 / (bounds.max.y - bounds.min.y);
  figure.scale.multiplyScalar(scale);
  figure.position.set(-center.x * scale, -center.y * scale, -center.z * scale);

  const turntable = new Group();
  turntable.add(figure);
  const scene = new Scene();
  scene.add(turntable);
  scene.add(new HemisphereLight(0xfff4e9, 0x6d635e, 0.8));
  addLight(scene, 0xffdfc2, 2, -3.5, 5, 5);
  addLight(scene, 0xd5deff, 0.45, 4, 1, 3);
  addLight(scene, 0xffdebc, 1.85, 1, 5, -5);

  const camera = new OrthographicCamera(-1, 1, 1, -1, 0.1, 30);
  camera.position.set(-4.2, 2.25, 10.5);
  camera.lookAt(0, 0, 0);

  let environment;
  function isAvailable() {
    return environment !== undefined && !renderer.getContext().isContextLost();
  }

  function render() {
    if (isAvailable()) renderer.render(scene, camera);
  }

  function restoreLighting() {
    if (renderer.getContext().isContextLost()) return;

    environment?.dispose();
    const room = new RoomEnvironment();
    const pmrem = new PMREMGenerator(renderer);
    environment = pmrem.fromScene(room, 0.06);
    room.dispose();
    pmrem.dispose();
    scene.environment = environment.texture;
    scene.environmentIntensity = 0.45;
    resize();
  }

  function resize() {
    const { clientWidth: width, clientHeight: height } = canvas;
    if (!width || !height) return;

    const halfHeight = viewHeight / 2;
    camera.left = -halfHeight * width / height;
    camera.right = halfHeight * width / height;
    camera.top = halfHeight;
    camera.bottom = -halfHeight;
    camera.updateProjectionMatrix();
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    renderer.setSize(width, height, false);
    render();
  }

  restoreLighting();
  new ResizeObserver(resize).observe(canvas);

  return {
    isAvailable,
    restoreLighting,
    resetTurn() {
      turntable.rotation.y = 0;
      render();
    },
    pose(target, turn, seconds) {
      // Let the head lag slightly behind the desk during a flick of the turntable.
      const turnSpeed = seconds ? Math.max(-9, Math.min(9, turn / seconds)) : 0;
      const pose = turnSpeed ? {
        ...target,
        yaw: target.yaw - 0.02 * turnSpeed,
        roll: target.roll + 0.012 * turnSpeed,
      } : target;
      let changed = false;
      let settling = false;
      for (const [name, joint] of joints) {
        const previous = joint.value;
        stepSpring(joint, pose[name], seconds);
        changed ||= joint.value !== previous;
        settling ||= joint.value !== pose[name] || joint.velocity !== 0;
      }
      if (!changed && !turn) return settling;

      const pitch = motion.pitch.value;
      const roll = motion.roll.value;
      const yaw = motion.yaw.value;
      const lift = motion.lift.value;
      turntable.rotation.y = (turntable.rotation.y + turn) % fullTurn;

      const forwardBend = 0.83 * Math.sin(pitch);
      const sideBend = -0.5 * Math.sin(roll);
      const headOffset = lift - 0.1 * Math.sin(pitch) - 0.022 * (1 - Math.cos(roll));
      head.rotation.x = restPitch + pitch;
      head.rotation.y = restYaw + yaw;
      head.rotation.z = restRoll + roll;
      head.position.y = restHead.y + headOffset;
      spring.scale.y = restSpringScale * (1 + headOffset / neckHeight);
      if (flex) {
        head.position.x = restHead.x + coilBendDistance * sideBend;
        head.position.z = restHead.z + coilBendDistance * forwardBend;
        flex[0] = forwardBend;
        flex[1] = sideBend;
      }

      render();
      return settling;
    },
  };
}

function addSideBend(coil) {
  const targets = coil?.geometry.morphAttributes.position;
  if (!targets?.length) return undefined;

  // The original bend moves the coil along Z. Reuse its profile along X.
  const forward = targets[0];
  const side = forward.clone();
  side.name = "SideBend";
  for (let index = 0; index < side.count; index++) {
    side.setXYZ(index, forward.getZ(index), 0, 0);
  }
  targets.push(side);
  coil.updateMorphTargets();
  return coil.morphTargetInfluences;
}

function springMotion(frequency, damping) {
  const speed = fullTurn * frequency;
  return {
    value: 0,
    velocity: 0,
    decay: speed * damping,
    swing: speed * Math.sqrt(1 - damping ** 2),
  };
}

function stepSpring(joint, target, seconds) {
  const { value, velocity, decay, swing } = joint;
  const offset = value - target;
  if (!seconds || (Math.abs(offset) < 0.0002 && Math.abs(velocity) < 0.004)) {
    joint.value = target;
    joint.velocity = 0;
    return;
  }

  // Solve the damped spring over this frame so its response is refresh-rate independent.
  const ring = (velocity + decay * offset) / swing;
  const cosine = Math.cos(swing * seconds);
  const sine = Math.sin(swing * seconds);
  const envelope = Math.exp(-decay * seconds);
  const displacement = offset * cosine + ring * sine;
  joint.value = target + envelope * displacement;
  joint.velocity = envelope * (swing * (ring * cosine - offset * sine) - decay * displacement);
}

function addLight(scene, color, intensity, x, y, z) {
  const light = new DirectionalLight(color, intensity);
  light.position.set(x, y, z);
  scene.add(light);
}
