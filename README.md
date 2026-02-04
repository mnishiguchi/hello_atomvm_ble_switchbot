# Hello AtomVM BLE SwitchBot

A tiny AtomVM port driver (ESP-IDF component) that scans BLE (NimBLE),
merges SwitchBot advertisement fragments, and exposes a minimal request/response
API to an Elixir app running on ESP32.

Tested on ESP32-S3. The example is intended to work on AtomVM-supported ESP32 targets.

```

    ###########################################################

       ###    ########  #######  ##     ## ##     ## ##     ##
      ## ##      ##    ##     ## ###   ### ##     ## ###   ###
     ##   ##     ##    ##     ## #### #### ##     ## #### ####
    ##     ##    ##    ##     ## ## ### ## ##     ## ## ### ##
    #########    ##    ##     ## ##     ##  ##   ##  ##     ##
    ##     ##    ##    ##     ## ##     ##   ## ##   ##     ##
    ##     ##    ##     #######  ##     ##    ###    ##     ##

    ###########################################################

I (622) AtomVM: Starting AtomVM revision 0.7.0-dev+git.dbc1540
I (622) sys: Loaded BEAM partition boot.avm at address 0x1d0000 (size=524288 bytes)
I (652) network_driver: Initialized network interface
I (652) network_driver: Created default event loop
I (682) AtomVM: Found startup beam esp32init.beam
I (682) AtomVM: Starting esp32init.beam...
---
AtomVM init.
I (742) sys: Loaded BEAM partition main.avm at address 0x250000 (size=1048576 bytes)
Starting application...
Port opened: #Port<0.4>
I (772) BLE_INIT: BT controller compile version [4713a69]
I (772) BLE_INIT: Feature Config, ADV:1, BLE_50:1, DTM:1, SCAN:1, CCA:0, SMP:1, CONNECT:1
I (772) BLE_INIT: Bluetooth MAC: 74:4d:bd:xx:xx:xx
I (782) phy_init: phy_version 701,f4f1da3a,Mar  3 2025,15:50:10
I (822) NimBLE: GAP procedure initiated: stop advertising.

I (822) NimBLE: Failed to restore IRKs from store; status=8

I (822) sample_app_port: ble_hs_id_infer_auto rc=0, addr_type=0
I (832) sample_app_port: scan params passive=0 itvl=16 window=16 filter_duplicates=0
I (832) NimBLE: GAP procedure initiated: discovery;
I (842) NimBLE: own_addr_type=0 filter_policy=0 passive=0 limited=0 filter_duplicates=0
I (852) NimBLE: duration=forever
I (852) NimBLE:

I (852) sample_app_port: ble_gap_disc rc=0
BLE scan started
No SwitchBot frame yet
I (1822) sample_app_port: MERGED addr=d1:2d:01:xx:xx:xx rssi=-46 mfg_len=13 svc_len=6
[METER] id=xxxx addr=d1:2d:01:xx:xx:xx rssi=-53 batt=100% temp=18.5C hum=38% pir=-
```

## What you get

- Native side: ESP-IDF component (`sample_app_port`) using NimBLE
- Elixir side: small demo app that polls “latest frame”, decodes it, prints one line

## Requirements

- ESP-IDF installed (the script expects an ESP-IDF environment)
- Serial port access to your board (e.g. `/dev/ttyACM0`)

## Quickstart

```sh
git clone https://github.com/piyopiyoex/hello_atomvm_port.git
cd hello_atomvm_port

# Build + flash AtomVM firmware (includes this ESP-IDF component)
bash scripts/atomvm-esp32.sh install --target esp32s3 --port /dev/ttyACM0

# Build + flash the Elixir example app
cd examples/elixir
mix deps.get
mix do clean + atomvm.esp32.flash --port /dev/ttyACM0

# Monitor serial output
cd ../..
bash scripts/atomvm-esp32.sh monitor --port /dev/ttyACM0
```
