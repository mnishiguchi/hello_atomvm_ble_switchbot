defmodule SampleApp.Port do
  @moduledoc """
  Thin wrapper around the native AtomVM port driver (`sample_app_port`).

  The driver runs BLE scanning (NimBLE), merges SwitchBot advertisement fragments,
  and exposes a small request/response API via `:port.call/2`.

  ## Wire protocol

  Requests are binaries:

      <<opcode, payload::binary>>

  Replies are binaries:

  - `<<0x00, rest::binary>>` success
  - `<<0x01, code>>` driver error (one byte error code)

  This module converts those into `{:ok, binary}` / `{:error, term}` tuples.

  ## Notes

  - Uses `{:spawn_driver, 'sample_app_port'}` so AtomVM loads the registered
    port driver from the firmware image (not an external OS process).
  - Keep this API minimal for v1; decoding happens in `SampleApp.SwitchBot`.
  """

  @compile {:no_warn_undefined, :port}

  @driver ~c"sample_app_port"

  # --- request opcodes (first byte of request) ---
  @opcode_ping 0x01
  @opcode_echo 0x02

  @opcode_ble_start 0x10
  @opcode_ble_stop 0x11

  @opcode_latest 0x12
  @opcode_latest_for_id 0x13

  # --- response tags (first byte of response) ---
  @reply_ok 0x00
  @reply_error 0x01

  @typedoc "AtomVM port handle."
  @type avm_port :: port()

  @typedoc "Driver opcode (first byte of the request)."
  @type opcode :: 0..255

  @typedoc "Driver error code returned as `{:driver_error, code}`."
  @type driver_error :: {:driver_error, 0..255}

  @typedoc "Result returned by port calls."
  @type result :: {:ok, binary()} | {:error, driver_error() | {:bad_reply, term()}}

  @doc """
  Open the native port driver.
  """
  @spec open() :: avm_port()
  def open() do
    :erlang.open_port({:spawn_driver, @driver}, [:binary])
  end

  @doc """
  Simple liveness check.

  Returns `{:ok, "PONG"}` on success.
  """
  @spec ping(avm_port()) :: result()
  def ping(port), do: call(port, @opcode_ping)

  @doc """
  Echo test for validating request/response wiring.

  Returns the same payload that was sent.
  """
  @spec echo(avm_port(), binary()) :: result()
  def echo(port, payload) when is_binary(payload) do
    call(port, @opcode_echo, payload)
  end

  @doc """
  Start BLE scanning on the native side.

  The driver lazy-initializes NVS + NimBLE on the first call.
  """
  @spec ble_start(avm_port()) :: result()
  def ble_start(port), do: call(port, @opcode_ble_start)

  @doc """
  Stop BLE scanning (does not deinitialize NimBLE).
  """
  @spec ble_stop(avm_port()) :: result()
  def ble_stop(port), do: call(port, @opcode_ble_stop)

  @doc """
  Return the latest merged SwitchBot frame seen by the scanner.

  On success, the payload is the merged frame binary (without the `0x00` status byte).
  The payload format is documented in `SampleApp.SwitchBot.parse_frame!/1`.

  Driver error `0x41` means "no data yet".
  """
  @spec latest(avm_port()) :: result()
  def latest(port), do: call(port, @opcode_latest)

  @doc """
  Return the latest merged frame for a specific SwitchBot `device_id`.

  The `device_id` is a best-effort 16-bit id derived from manufacturer data.
  """
  @spec latest_for_id(avm_port(), 0..0xFFFF) :: result()
  def latest_for_id(port, id) when is_integer(id) and id in 0..0xFFFF do
    call(port, @opcode_latest_for_id, <<id::16-big>>)
  end

  @spec call(avm_port(), opcode(), binary()) :: result()
  defp call(port, opcode, payload \\ <<>>) do
    req = <<opcode, payload::binary>>

    case :port.call(port, req) do
      <<@reply_ok, rest::binary>> -> {:ok, rest}
      <<@reply_error, code>> -> {:error, {:driver_error, code}}
      other -> {:error, {:bad_reply, other}}
    end
  end
end
