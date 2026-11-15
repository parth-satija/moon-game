class_name Mat
extends RefCounted
## The ten salvageable materials. These strings are the item names used by Inventory, Repairs and the save files,
## so use Mat.ALLOY (etc.) in code instead of typing them out.

const ALLOY := "Structural Alloy Plates"
const WIRING := "Electrical Wiring"
const CIRCUIT := "Circuit Boards"
const BATTERY := "Battery Modules"
const SOLAR := "Solar Cell Modules"
const MECHANICAL := "Mechanical Assemblies"
const HYDRAULIC := "Hydraulic Components"
const THERMAL := "Thermal Seals and Insulation"
const AVIONICS := "Avionics Components"
const PROPULSION := "Propulsion Components"

const ALL := [ALLOY, WIRING, CIRCUIT, BATTERY, SOLAR, MECHANICAL, HYDRAULIC, THERMAL, AVIONICS, PROPULSION]
