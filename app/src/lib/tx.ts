"use client";

import { useState } from "react";
import { useConfig } from "wagmi";
import { waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { useQueryClient } from "@tanstack/react-query";
import { BaseError } from "viem";

type WriteArgs = Parameters<typeof writeContract>[1];

/** Runs one or more contract writes in sequence (e.g. approve -> action), waiting for each receipt. */
export function useTxRunner() {
  const config = useConfig();
  const qc = useQueryClient();
  const [status, setStatus] = useState<string>("");
  const [busy, setBusy] = useState(false);

  async function run(steps: { label: string; args: WriteArgs }[]) {
    setBusy(true);
    try {
      for (const step of steps) {
        setStatus(`${step.label}: confirm in wallet...`);
        const hash = await writeContract(config, step.args);
        setStatus(`${step.label}: pending ${hash.slice(0, 10)}...`);
        const receipt = await waitForTransactionReceipt(config, { hash });
        if (receipt.status !== "success") throw new Error(`${step.label} reverted`);
      }
      setStatus("Done");
      await qc.invalidateQueries();
      return true;
    } catch (e) {
      const msg = e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : String(e);
      setStatus(`Error: ${msg}`);
      return false;
    } finally {
      setBusy(false);
    }
  }

  return { run, status, busy, setStatus };
}
