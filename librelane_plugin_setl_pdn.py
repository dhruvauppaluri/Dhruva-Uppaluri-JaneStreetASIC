# Vendored from Ken Pettit's ihp-um-janestreet-prism (Apache-2.0,
# https://github.com/kdp1965/ihp-um-janestreet-prism): the CMOS5L SRAM power
# integration steps only.  The scripts it runs live in physical/.
"""
LibreLane plugin: extend the tile's Metal4 power stripes over the CFGMEM
macros (see odb_stripes.py for what the step does and why).

LibreLane imports every module on the Python path whose name starts with
``librelane_plugin_`` (librelane/plugins.py).  ``python -m librelane`` puts
the current directory on that path, and both the Tiny Tapeout GDS action
and ``make harden`` run it from the repository root, so this file is found
without installing anything.  src/config.json then inserts the step after
the PDN generator through ``meta.substituting_steps``:

    "meta": { "substituting_steps": { "+OpenROAD.GeneratePDN": "Project.ExtendPowerStripes" } }

flow.py uses the same step class for the local flow.
"""
import os

from librelane.steps import Step
from librelane.steps.odb import OdbpyStep
from librelane.state import DesignFormat
from librelane.config import Variable
from typing import Optional
from librelane.common import Path
from decimal import Decimal

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "physical")


@Step.factory.register()
class ExtendPowerStripes(OdbpyStep):
    id = "Project.ExtendPowerStripes"
    name = "Extend Power Stripes Over Macros"

    def get_script_path(self):
        return os.path.join(HERE, "odb_stripes.py")

    config_vars = [
        Variable("EXTEND_STRIPES_LAYER", str, "The tile's vertical single-layer PDN layer (Metal4 on the CMOS5L tile, TopMetal1 on the sg13g2 tile).", default="Metal4"),
        Variable("EXTEND_STRIPES_SRAM_LAYER", Optional[str], "Layer of the IHP SRAM power columns when it differs from the stripe layer; the column stripes then get via stacks down to it.", default=None),
        Variable("EXTEND_STRIPES_CLEARANCE", Decimal, "Spacing kept between a drawn stripe and the other net's macro rails or tile pins on the stripe layer.", units="µm", default=Decimal("0.24")),
        Variable("EXTEND_STRIPES_STACK_PITCH", Decimal, "Spacing of the via stacks along an SRAM power column.", units="µm", default=Decimal("10")),
        Variable("EXTEND_STRIPES_PIN_FACE_MARGIN", Decimal, "No rail via stack within this distance of a macro edge that carries pins (the stack would block the pins' escape); 0 leaves pdngen's stacks alone.", units="µm", default=Decimal("3")),
        Variable("EXTEND_STRIPES_SRAM_ALL_COLUMNS", bool, "Put a stripe on every legal supply column of an IHP SRAM rather than only the ones the tile grid and the per-region minimum need.", default=False),
        Variable("EXTEND_STRIPES_SRAM_ARRAY_EVERY_OTHER", bool, "In each bit-cell array of an IHP SRAM, add a VPWR/VGND stripe pair on every other available pair position (the grid's pairs stay; the macro's standard-cell band is left as the grid gives it).  Not with EXTEND_STRIPES_SRAM_ALL_COLUMNS.", default=False),
    ]

    def get_command(self):
        cmd = super().get_command() + [
            "--layer", self.config["EXTEND_STRIPES_LAYER"],
            "--clearance", str(self.config["EXTEND_STRIPES_CLEARANCE"]),
            "--stack-pitch", str(self.config["EXTEND_STRIPES_STACK_PITCH"]),
            "--pin-face-margin", str(self.config["EXTEND_STRIPES_PIN_FACE_MARGIN"]),
        ]
        if self.config.get("EXTEND_STRIPES_SRAM_LAYER"):
            cmd += ["--sram-layer", self.config["EXTEND_STRIPES_SRAM_LAYER"]]
        cmd += ["--sram-all-columns" if self.config["EXTEND_STRIPES_SRAM_ALL_COLUMNS"] else "--sram-grid-columns"]
        if self.config["EXTEND_STRIPES_SRAM_ARRAY_EVERY_OTHER"]:
            cmd += ["--sram-array-every-other"]
        return cmd


# --- one antenna diode on every signal input pin of the IHP SRAMs (their LEF
# has no antenna data, so the rule-based repair cannot see those nets), then a
# detailed placement to legalise them.  Inserted before the first global
# routing (meta.substituting_steps "+OpenROAD.ResizerTimingPostCTS") so that
# single routing pass covers the diodes; the antenna repair later works
# incrementally on those routes and needs no extra global-routing pass.
from typing import List  # noqa: E402

from librelane.steps.step import CompositeStep  # noqa: E402
from librelane.steps.openroad import DetailedPlacement  # noqa: E402


@Step.factory.register()
class SramPinDiodePlacement(OdbpyStep):
    id = "Project.SramPinDiodePlacement"
    name = "Diodes on SRAM Input Pins"

    def get_script_path(self):
        return os.path.join(HERE, "odb_sram_diodes.py")

    def get_command(self) -> List[str]:
        cell, pin = self.config["DIODE_CELL"].split("/")
        return super().get_command() + ["--diode-cell", cell, "--diode-pin", pin, "--macro-prefix", "RM_IHPSG13"]


@Step.factory.register()
class DiodesOnSramPins(CompositeStep):
    id = "Project.DiodesOnSramPins"
    name = "Diodes on SRAM Pins"
    Steps = [SramPinDiodePlacement, DetailedPlacement]
