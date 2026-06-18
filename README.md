# AirHRM-DIY

Ponte fai-da-te: legge l'HR degli **AirPods Pro 3** via una sessione di allenamento
iOS (HealthKit) e lo ri-emette come **sensore cardiaco BLE standard** (GATT Heart Rate
Service `0x180D`). Il tuo **Garmin Forerunner 265** lo accoppia come se fosse una fascia
toracica, e l'attività registra l'HR degli AirPods.

**Requisiti:** AirPods Pro 3 · iPhone con iOS 26+ · Mac con Xcode.

---

## 1. Crea il progetto in Xcode (sul Mac)

1. **File → New → Project → iOS → App**.
2. Interface: **SwiftUI**, Language: **Swift**.
3. Bundle ID a piacere, es. `com.tuonome.airhrmdiy` (cambialo anche nel `Logger` se vuoi).
4. Sostituisci/aggiungi i file di questa cartella:
   - `AirHRM_DIYApp.swift`  (entry point + UI)
   - `HeartRateBridge.swift` (il cuore: HealthKit + CoreBluetooth)
5. Imposta i permessi e le capability come da `Info-plist-keys.md`.
6. **Signing & Capabilities**:
   - Team: il tuo **Apple ID personale** (gratuito) → "Personal Team".
   - **+ Capability → HealthKit**.
   - **+ Capability → Background Modes** → spunta *Workout processing* e
     *Acts as a Bluetooth LE accessory*.
   - Verifica che l'`.entitlements` contenga le chiavi HealthKit (incluso il file di
     questa cartella se preferisci usarlo direttamente).

## 2. Primo run (sviluppo, via cavo)

1. Collega l'iPhone, selezionalo come destinazione, **Run** (⌘R).
2. Su iPhone: **Impostazioni → Generali → VPN e gestione dispositivo** → fidati del tuo
   certificato sviluppatore.
3. Avvia l'app, premi **Avvia ponte HR**, concedi i permessi Health + Bluetooth.
4. Indossa gli AirPods Pro 3: dopo qualche secondo dovresti vedere i BPM.

## 3. Accoppia il Garmin FR265

1. Sul watch: **tieni UP → Sensori e Accessori → Aggiungi nuovo → Cerca tutto → Freq.
   cardiaca**.
2. Cerca il sensore chiamato **`AirHRM-DIY`** e accoppialo.
3. Avvia un'attività: il watch userà l'HR esterno (AirPods) al posto del polso.
   Puoi impostarlo per-attività se vuoi tenerlo solo per gli intervalli.

## 4. Distribuzione "daily driver" con AltStore / SideStore

Con account gratuito la firma **scade dopo 7 giorni**: AltStore/SideStore la rinnovano
in automatico così non ricompili a mano.

**AltStore**
1. Installa **AltServer** su Mac/PC; installa **AltStore** sull'iPhone via AltServer.
2. In Xcode: **Product → Archive** non è necessario per il free signing — esporta un
   `.ipa` (o usa il `.app` buildato) e in AltStore **+ → installa da .ipa**.
3. AltStore ri-firma in background **finché AltServer è raggiungibile sulla stessa Wi-Fi**.

**SideStore** (consigliato se non vuoi un computer sempre acceso)
1. Genera il **pairing file** (via SideStore/AltServer una volta sola).
2. SideStore usa un tunnel WireGuard locale per auto-rinnovare **senza** server fisso.

> Limiti del free provisioning: max **3 app** sideloaded, pochi App ID a settimana,
> niente App Store/TestFlight. Per uso personale è sufficiente.

---

## Note tecniche / possibili estensioni

- **Perché serve la sessione di allenamento:** l'HR degli AirPods è esposto solo a un'app
  che ha una sessione workout iOS attiva (HealthKit). Senza, il sensore resta spento.
- **Formato del pacchetto BLE:** `[flags=0x00, bpm(uint8)]`. Per HR > 255 (mai per umani)
  passeresti a uint16 mettendo il bit0 dei flags a 1.
- **Body Sensor Location** è impostato su *Ear Lobe* (`0x05`) — cosmetico, alcuni ricevitori
  lo mostrano.
- **Idee:** fondere l'HR AirPods con un secondo sensore, filtro/smoothing custom,
  rilevare il calo di contatto (dashes) e segnalare "contact lost", auto-start del ponte
  quando colleghi gli AirPods (via osservazione route audio).
- **Onestà sui costi:** tecnicamente gira gratis; i 99 $/anno della membership servirebbero
  solo a togliere la scadenza settimanale. L'app commerciale AirHRM costa ~€6/anno — il DIY
  ha senso per controllo/estensioni, non per risparmiare.
