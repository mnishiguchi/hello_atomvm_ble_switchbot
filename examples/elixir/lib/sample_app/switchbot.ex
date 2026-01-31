defmodule SampleApp.SwitchBot do
  @moduledoc """
  SwitchBot advertisement decoder for the AtomVM BLE port demo.

  The native port handles BLE scanning and merges advertisement fragments.
  Elixir receives one merged binary per device and decodes it into readings.

  Public entry points:

  - `parse_frame!/1` parses the port payload into a map.
  - `decode/1` converts the map into a typed reading tuple.
  """

  import Bitwise

  @typedoc "BLE device address (MAC) as a 6-byte binary."
  @type mac_addr :: <<_::48>>

  @typedoc """
  Parsed merged frame from the native port.

  Keys:

  - `:addr` 6-byte device address
  - `:rssi` RSSI in dBm
  - `:svc` SwitchBot service data payload (starts with model byte)
  - `:mfg` manufacturer data payload
  - `:device_id` best-effort id derived from `mfg`
  """
  @type frame :: %{
          addr: mac_addr(),
          rssi: integer(),
          svc: binary(),
          mfg: binary(),
          device_id: non_neg_integer() | nil
        }

  @typedoc """
  Motion flag reported by SwitchBot sensors.

  `0` means "no motion", `1` means "motion detected".

  The name comes from "Passive Infrared (PIR)", a common motion sensor type.
  """
  @type pir_flag :: 0 | 1

  # SwitchBot model identifiers (first byte of `svc`).
  @type model :: 0x54 | 0x77 | 0x64 | 0x73
  @model_meter 0x54
  @model_outdoor_meter 0x77
  @model_contact 0x64
  @model_motion 0x73

  @typedoc """
  Decoded SwitchBot reading.

  `*_raw` indicates a recognized model but insufficient payload length to decode.
  """
  @type reading ::
          {:meter, frame()}
          | {:meter_raw, frame()}
          | {:contact, frame()}
          | {:contact_raw, frame()}
          | {:motion, frame()}
          | {:motion_raw, frame()}
          | {:unknown, frame()}

  # Minimum payload lengths for decoding.
  @min_meter_svc_len 3
  @min_meter_mfg_len 13
  @min_contact_svc_len 9
  @min_motion_svc_len 6

  @doc """
  Parse a merged frame from the native port.

  The port returns:

      <<addr::binary-6,
        rssi::signed-8,
        svc_len::unsigned-8, svc::binary-size(svc_len),
        mfg_len::unsigned-8, mfg::binary-size(mfg_len)>>

  Returns a `t:frame/0` map.
  """
  @spec parse_frame!(binary()) :: frame()
  def parse_frame!(<<addr::binary-6, rssi::signed-8, svc_len::unsigned-8, rest::binary>>) do
    <<svc::binary-size(svc_len), mfg_len::unsigned-8, mfg::binary-size(mfg_len)>> = rest

    %{
      addr: addr,
      rssi: rssi,
      svc: svc,
      mfg: mfg,
      device_id: device_id(mfg)
    }
  end

  @doc """
  Decode a parsed `t:frame/0` into a typed SwitchBot reading.

  Uses the first byte of `svc` as the SwitchBot model id.
  Returns `{:unknown, frame}` if `svc` is empty or the model is not recognized.
  """
  @spec decode(frame()) :: reading()
  def decode(%{svc: <<>>} = frame), do: {:unknown, frame}

  def decode(%{svc: <<model, _::binary>>} = frame) do
    case model do
      @model_meter -> decode_meter(frame)
      @model_outdoor_meter -> decode_meter(frame)
      @model_contact -> decode_contact(frame)
      @model_motion -> decode_motion(frame)
      _ -> {:unknown, frame}
    end
  end

  # Best-effort device id extraction from manufacturer data.
  # Convention: device_id = (mfg[6] << 8) | mfg[7]
  @spec device_id(binary()) :: non_neg_integer() | nil
  defp device_id(<<_::binary-6, hi::unsigned-8, lo::unsigned-8, _::binary>>) do
    u16(hi, lo)
  end

  defp device_id(_), do: nil

  defp decode_meter(%{svc: svc, mfg: mfg} = frame) do
    # Meter / Outdoor Meter (models 0x54, 0x77)
    with true <- byte_size(svc) >= @min_meter_svc_len,
         true <- byte_size(mfg) >= @min_meter_mfg_len do
      <<_model, _b1, b2, _::binary>> = svc
      battery = b2 &&& 0x7F

      <<_::binary-10, t10, t11, t12, _::binary>> = mfg
      above_freezing = (t11 &&& 0x80) != 0

      temp = (t10 &&& 0x0F) / 10.0 + (t11 &&& 0x7F)
      temperature_c = if above_freezing, do: temp, else: -temp
      humidity_percent = t12 &&& 0x7F

      {:meter,
       put_reading(frame,
         battery: battery,
         temperature_c: temperature_c,
         humidity_percent: humidity_percent
       )}
    else
      _ -> {:meter_raw, frame}
    end
  end

  defp decode_contact(%{svc: svc} = frame) do
    # Contact sensor (model 0x64)
    with true <- byte_size(svc) >= @min_contact_svc_len do
      <<_model, b1, b2, b3, t4, t5, t6, t7, b8, _::binary>> = svc

      battery = b2 &&& 0x7F
      pir = bit_to_01(b1 &&& 0x40)
      door = bit_to_01(b3 &&& 0x02)
      door_timeout = bit_to_01(b3 &&& 0x04)
      illuminance_flag = bit_to_01(b3 &&& 0x01)
      button_count = b8 &&& 0x0F

      time01 = u16(t4, t5)
      time02 = u16(t6, t7)

      {:contact,
       put_reading(frame,
         battery: battery,
         pir: pir,
         door: door,
         door_timeout: door_timeout,
         illuminance_flag: illuminance_flag,
         button_count: button_count,
         time01: time01,
         time02: time02
       )}
    else
      _ -> {:contact_raw, frame}
    end
  end

  defp decode_motion(%{svc: svc} = frame) do
    # Motion sensor (model 0x73)
    with true <- byte_size(svc) >= @min_motion_svc_len do
      <<_model, b1, b2, b3, b4, b5, _::binary>> = svc

      battery = b2 &&& 0x7F
      pir = bit_to_01(b1 &&& 0x40)
      time01 = u16(b3, b4)

      # A small light-level bucket reported by the device.
      # (The exact meaning is device-specific; we keep it as-is.)
      illuminance = (b5 &&& 0x03) - 1

      {:motion,
       put_reading(frame,
         battery: battery,
         pir: pir,
         time01: time01,
         illuminance: illuminance
       )}
    else
      _ -> {:motion_raw, frame}
    end
  end

  # Apply extra fields to a frame without Map.merge/2 or Enum usage.
  @spec put_reading(frame(), keyword()) :: frame()
  defp put_reading(frame, extra), do: put_kv(frame, extra)

  @spec put_kv(frame(), keyword()) :: frame()
  defp put_kv(frame, []), do: frame
  defp put_kv(frame, [{k, v} | rest]), do: put_kv(Map.put(frame, k, v), rest)

  @spec u16(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp u16(hi, lo), do: hi <<< 8 ||| lo

  @spec bit_to_01(non_neg_integer()) :: 0 | 1
  defp bit_to_01(0), do: 0
  defp bit_to_01(_), do: 1
end
