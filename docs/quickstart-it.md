# Iniziare con Emacs Multihost

Il progetto organizza operazioni su gruppi di server usando Emacs, Org Babel e
TRAMP. L'installazione Emacs personale da cui siamo partiti rimane invariata.

1. Clona il repository e aggiungi la directory al `load-path`, come nel README.
2. Carica `multihost` e `ob-multihost`, quindi abilita `ob-multihost-mode`.
3. Crea un inventario JSON seguendo `examples/inventory.json`. Gli host di esempio
   sono fittizi: usa alias della tua configurazione SSH o percorsi TRAMP completi.
4. Apri `M-x multihost`: `m` marca un host, `T` li marca tutti, `x` invia un
   comando. `C-u x` esegue un host alla volta nell'ordine dell'inventario.
5. Nella dashboard, `RET` apre il risultato dell'host, `a` riunisce gli output,
   `d` raggruppa quelli identici, `r` ritenta solo gli host non riusciti e `c`
   interrompe il lavoro locale e la coda.

Per un'attività ripetibile, salva il codice in Org:

```org
#+begin_src sh :hosts @web :concurrency 1 :timeout 60 :renderer combined
hostname
uptime
#+end_src
```

`M-x multihost-org-preview` mostra il piano senza collegarsi. `C-c C-c` avvia il
lavoro rispettando la conferma di Org. Se modifichi il blocco mentre è in corso,
i risultati rimangono nella cronologia e non sovrascrivono il documento modificato.

Per preparare gli host prima di lavorare, marcali nell'inventario e premi `w`.
L'inizializzazione avviene in processi separati; `C` mostra connessioni e worker
conservati, `k` ne chiude uno. I blocchi successivi riutilizzano la connessione.
Il limite globale è `multihost-connection-limit` (quattro per impostazione
predefinita), anche quando più runbook e completamenti sono attivi insieme.

Nel corpo di un blocco shell con `:hosts`, scrivi per esempio `cat conf`, poi usa
`M-x multihost-org-completion-enable`. `M-TAB` propone comandi o file rilevati sui
server selezionati. La prima richiesta può essere ancora in corso: richiama il
completamento dopo la risposta. Le annotazioni indicano gli host di provenienza;
`multihost-completion-policy` sceglie unione o intersezione. `C-c '` eredita
l'abilitazione nel buffer di editing shell. Per fermarlo usa
`M-x multihost-org-completion-disable`. `M-x multihost-completion-inspect` mostra
lo stato di ogni host e gli eventuali errori senza avviare nuove richieste.

Serve Bash remoto per `compgen`; sono supportati nomi di comandi e file con
prefissi semplici, non le opzioni specifiche dei programmi. I dettagli e le
misure riproducibili sono nella [guida alle connessioni e al completamento](connections-and-completion.md).

Per PSMP e MFA, il percorso esplicito `M-x multihost-org-execute-foreground`
usa l'autenticazione interattiva TRAMP dell'Emacs corrente e procede in serie.
Non ha il timeout rigido del background: `C-g` interrompe. Gli alias e le policy
CyberArk devono essere quelli approvati dalla tua organizzazione; il laboratorio
SSH locale non certifica il comportamento di un deployment PSMP reale.

Le sessioni interattive restano disponibili con `s` dall'inventario, i file con
`d`. Gli output dei job sono risultati consultabili a completamento, non terminali
in streaming. Il [README](../README.md) specifica il contratto completo.
