# Hello AtomVM BLE SwitchBot

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
