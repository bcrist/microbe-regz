# Microbe Register Access Code Generation

This project takes a JSON output file from [regz](/ZigEmbeddedGroup/regz) and generates Zig code for a [microbe](/bcrist/microbe) device.

Note only Arm SVD files are currently supported.

## Usage
1. Move to the device directory (should contain `device.svd` and a `reg_types` subdirectory)
2. Run `regz device.svd -j -o device.json`
3. Run `microbe-regz`

## Building
1. Run `zig build`
2. Add/copy `zig-out/bin/microbe-regz` to your path
3. Build regz and add it to your path as well, if you don't already have a .json file to work with

## See Also
* [microbe-stm32](/bcrist/microbe-stm32)
* [microbe-rpi](/bcrist/microbe-rpi)
