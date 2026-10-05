# RCN Network Source of Truth (NSOT)

Infrastructure-as-code for the RoboControl Networks lab topology.
Device configuration is defined once as structured data, rendered through
vendor templates, version-controlled in git, and snapshotted as golden configs.

## Layout

```
data/            one YAML file per device -- THE source of truth
templates/       Jinja2 templates, one per vendor
configs/         rendered device configs (generated -- do not hand-edit)
golden/          timestamped snapshots of known-good configs
scripts/
  render.py      YAML + template -> configs/
  golden.py      snapshot / list / diff golden configs
app.py           Flask web GUI
```

## Quick start

```bash
pip install -r requirements.txt
python3 scripts/render.py      # render all device configs
python3 scripts/golden.py      # save a timestamped snapshot
python3 app.py                 # web GUI on http://localhost:5000
```

## Workflow

1. Edit a device's YAML in `data/` (or add one through the GUI).
2. Run `render.py` to regenerate `configs/`.
3. Review the diff, then commit -- git is the change-management record.
4. Run `golden.py` to snapshot the known-good state.
5. Copy `configs/*.cfg` into the containerlab topology and deploy.

Configs in `configs/` are build artifacts. Never edit them by hand; change
the YAML and re-render, or the source of truth stops being true.

## Adding a device through the GUI

`Add device` collects hostname, vendor/template, role, WAN IP, routing
protocol and collector address, writes the YAML, and renders the config
immediately. Commit the new file to record the change.

## Vendor templates

`arista_eos.j2` covers all eight current devices; role differences
(access router, core router, access switch, boundary switch) are driven by
the data rather than by separate templates. Adding a vendor means adding
`<vendor>.j2` and setting `vendor:` in that device's YAML -- `render.py`
picks the template by that field.
