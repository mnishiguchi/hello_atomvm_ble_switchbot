defmodule SampleApp do
  @moduledoc """
  Minimal SwitchBot BLE reader demo for AtomVM.

  This module is the "app loop" side of the demo:

  - Opens the native port driver (`SampleApp.Port`)
  - Starts BLE scanning on the native side
  - Polls for the latest merged SwitchBot frame
  - Decodes the frame in Elixir (`SampleApp.SwitchBot`)
  - Prints a compact one-line summary

  ## Why polling?

  The port API here is intentionally tiny: Elixir requests the latest merged
  advertisement frame on demand. This keeps v1 simple and avoids pushing events
  into Elixir processes.

  ## Device selection

  Set `@target_device_id` to lock onto a specific SwitchBot device id
  (a 16-bit value derived from manufacturer data; printed as `%04x` in logs).
  If `nil`, the demo prints whichever valid merged frame was seen most recently.
  """

  @poll_interval_ms 1_000

  @typedoc "16-bit SwitchBot device id (best-effort, derived from manufacturer data)."
  @type device_id :: 0..0xFFFF

  # If you want to lock onto a specific SwitchBot device ID (the 16-bit id you print as %04x),
  # set this to an integer like 0x8006. Otherwise leave it as nil to read the latest frame seen.
  @target_device_id nil
  # @target_device_id 0x8006

  @doc """
  Entry point for the demo.

  Opens the port, starts scanning, then loops forever printing readings.
  """
  @spec start() :: no_return()
  def start() do
    port = SampleApp.Port.open()
    IO.puts("Port opened: #{inspect(port)}")

    case SampleApp.Port.ble_start(port) do
      {:ok, _} ->
        IO.puts("BLE scan started")

      {:error, reason} ->
        IO.puts("BLE scan start failed: #{inspect(reason)}")
    end

    loop(port)
  end

  @spec loop(port()) :: no_return()
  defp loop(port) do
    case fetch_frame(port) do
      {:ok, payload} ->
        frame = SampleApp.SwitchBot.parse_frame!(payload)
        decoded = SampleApp.SwitchBot.decode(frame)
        print_decoded(decoded)

      {:error, {:driver_error, 0x41}} ->
        # Driver error 0x41: "no data yet"
        IO.puts("No SwitchBot frame yet")

      {:error, reason} ->
        IO.puts("Read failed: #{inspect(reason)}")
    end

    Process.sleep(@poll_interval_ms)
    loop(port)
  end

  @spec fetch_frame(port()) :: {:ok, binary()} | {:error, term()}
  defp fetch_frame(port) do
    case @target_device_id do
      nil -> SampleApp.Port.latest(port)
      id -> SampleApp.Port.latest_for_id(port, id)
    end
  end

  defp print_decoded({:meter, data}), do: print_common("METER", data)
  defp print_decoded({:motion, data}), do: print_common("MOTION", data)
  defp print_decoded({:contact, data}), do: print_common("CONTACT", data)
  defp print_decoded({:meter_raw, data}), do: print_common("METER(raw)", data)
  defp print_decoded({:motion_raw, data}), do: print_common("MOTION(raw)", data)
  defp print_decoded({:contact_raw, data}), do: print_common("CONTACT(raw)", data)
  defp print_decoded({:unknown, data}), do: print_common("UNKNOWN", data)

  defp print_common(kind, data) when is_map(data) do
    device_id =
      case Map.get(data, :device_id) do
        nil -> "----"
        id -> hex4(id)
      end

    addr = mac(data.addr)
    rssi = data.rssi

    battery =
      case Map.fetch(data, :battery) do
        {:ok, b} -> "#{b}%"
        :error -> "-"
      end

    temp =
      case Map.fetch(data, :temperature_c) do
        {:ok, t} -> "#{format_1dp(t)}C"
        :error -> "-"
      end

    hum =
      case Map.fetch(data, :humidity_percent) do
        {:ok, h} -> "#{h}%"
        :error -> "-"
      end

    pir =
      case Map.fetch(data, :pir) do
        {:ok, p} -> "#{p}"
        :error -> "-"
      end

    IO.puts(
      "[#{kind}] id=#{device_id} addr=#{addr} rssi=#{rssi} batt=#{battery} temp=#{temp} hum=#{hum} pir=#{pir}"
    )
  end

  # Format a 6-byte BLE address as `aa:bb:cc:dd:ee:ff`.
  #
  # We use `:io_lib.format/2` to avoid pulling in heavier formatting helpers.
  @spec mac(<<_::48>>) :: binary()
  defp mac(<<a, b, c, d, e, f>>) do
    :io_lib.format(
      ~c"~2.16.0b:~2.16.0b:~2.16.0b:~2.16.0b:~2.16.0b:~2.16.0b",
      [f, e, d, c, b, a]
    )
    |> :erlang.iolist_to_binary()
  end

  @spec hex4(0..0xFFFF) :: binary()
  defp hex4(n) when is_integer(n) and n in 0..0xFFFF do
    :io_lib.format(~c"~4.16.0b", [n]) |> :erlang.iolist_to_binary()
  end

  @spec format_1dp(number()) :: binary()
  defp format_1dp(f) when is_float(f) do
    :io_lib.format("~.1f", [f]) |> IO.iodata_to_binary()
  end

  defp format_1dp(i) when is_integer(i) do
    format_1dp(i * 1.0)
  end
end
