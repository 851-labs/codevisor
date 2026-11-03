import type { ReactElement } from "react"

import { Choice, titled } from "./controls/choice.js"
import { Slider } from "./controls/slider.js"
import { Toggle } from "./controls/toggle.js"
import {
  armLayers,
  armModes,
  armProps,
  armSides,
  overlayNames,
  withArm,
  type ArmControls,
  type ArmMode,
  type ArmSide,
  type Overlays,
  type RigControls
} from "./state.js"

export interface ArmPanelProps {
  readonly rig: RigControls
  readonly onChange: (rig: RigControls) => void
}

const overlayLabels: Readonly<Record<keyof Overlays, string>> = {
  silhouette: "Silhouette",
  edges: "Edges",
  outline: "Body outline",
  points: "Pose points"
}

const sideTitles: Readonly<Record<ArmSide, string>> = {
  left: "Left arm (screen left)",
  right: "Right arm (screen right)"
}

export function ArmPanel({ rig, onChange }: ArmPanelProps) {
  const setOverlay = (name: keyof Overlays, on: boolean) =>
    onChange({ ...rig, overlays: { ...rig.overlays, [name]: on } })
  return (
    <section className="panel">
      <header>
        <h2>Arm rig</h2>
        <Toggle label="On" checked={rig.on} onChange={(on) => onChange({ ...rig, on })} />
      </header>
      <p className="hint">Drag on the stage to move the nearest arm's target.</p>
      <div className="chips">
        {overlayNames.map((name) => (
          <Toggle
            key={name}
            label={overlayLabels[name]}
            checked={rig.overlays[name]}
            onChange={(on) => setOverlay(name, on)}
          />
        ))}
      </div>
      {armSides.map((side) => (
        <ArmEditor
          key={side}
          title={sideTitles[side]}
          arm={rig[side]}
          onChange={(patch) => onChange(withArm(rig, side, patch))}
        />
      ))}
    </section>
  )
}

interface ArmControlsProps {
  readonly arm: ArmControls
  readonly onChange: (patch: Partial<ArmControls>) => void
}

function ArmEditor({
  title,
  arm,
  onChange
}: {
  readonly title: string
  readonly arm: ArmControls
  readonly onChange: (patch: Partial<ArmControls>) => void
}) {
  return (
    <fieldset className="arm">
      <legend>
        <Toggle label={title} checked={arm.on} onChange={(on) => onChange({ on })} />
      </legend>
      <div className="row">
        <Choice
          label="Mode"
          value={arm.mode}
          options={titled(armModes)}
          onChange={(mode) => onChange({ mode })}
        />
        <Choice
          label="Layer"
          value={arm.layer}
          options={titled(armLayers)}
          onChange={(layer) => onChange({ layer })}
        />
      </div>
      <Slider
        label="Grow"
        value={arm.grow}
        min={0}
        max={1}
        step={0.01}
        onChange={(grow) => onChange({ grow })}
      />
      <ModeControls arm={arm} onChange={onChange} />
    </fieldset>
  )
}

function ModeControls({ arm, onChange }: ArmControlsProps) {
  const Controls = modeControls[arm.mode]
  return <Controls arm={arm} onChange={onChange} />
}

function ReachControls({ arm, onChange }: ArmControlsProps) {
  return (
    <>
      <Slider
        label="Target x"
        value={arm.x}
        min={0}
        max={500}
        step={1}
        onChange={(x) => onChange({ x })}
      />
      <Slider
        label="Target y"
        value={arm.y}
        min={0}
        max={500}
        step={1}
        onChange={(y) => onChange({ y })}
      />
      <div className="row">
        <Toggle
          label="Auto curl"
          checked={arm.autoCurl}
          onChange={(autoCurl) => onChange({ autoCurl })}
        />
        <Choice
          label="Prop"
          value={arm.prop}
          options={titled(armProps)}
          onChange={(prop) => onChange({ prop })}
        />
      </div>
      <Slider
        label="Curl °"
        value={arm.curl}
        min={-180}
        max={180}
        step={1}
        disabled={arm.autoCurl}
        onChange={(curl) => onChange({ curl })}
      />
    </>
  )
}

function DirectControls({ arm, onChange }: ArmControlsProps) {
  return (
    <>
      <Slider
        label="Angle ° ↓"
        value={arm.angle}
        min={-180}
        max={180}
        step={1}
        onChange={(angle) => onChange({ angle })}
      />
      <Slider
        label="Length"
        value={arm.length}
        min={5}
        max={240}
        step={1}
        onChange={(length) => onChange({ length })}
      />
      <Slider
        label="Bend °"
        value={arm.bend}
        min={-180}
        max={180}
        step={1}
        onChange={(bend) => onChange({ bend })}
      />
    </>
  )
}

const modeControls: Readonly<Record<ArmMode, (props: ArmControlsProps) => ReactElement>> = {
  reach: ReachControls,
  direct: DirectControls
}
