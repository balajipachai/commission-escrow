"use client";

// @refresh reset
import { useEffect, useState } from "react";
import { AddressInput } from "@scaffold-ui/components";
import { Contract } from "@scaffold-ui/debug-contracts";
import type { Address } from "viem";
import { useDeployedContractInfo, useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { useTargetNetwork } from "~~/hooks/scaffold-eth/useTargetNetwork";
import { ContractName } from "~~/utils/scaffold-eth/contract";

type ContractUIProps = {
  contractName: ContractName;
  className?: string;
};

// CommissionEscrow entries in deployedContracts.ts point at the factory's locked
// implementation contract (address(0) collector/artisan, permanently uninitialized) - it's
// only there to supply the ABI. Real commissions are EIP-1167 clones the factory creates at
// runtime, so this tab lets the user pick which clone to inspect instead of the implementation.
const CLONED_CONTRACT_NAME: ContractName = "CommissionEscrow" as ContractName;

/**
 * UI component to interface with deployed contracts.
 **/
export const ContractUI = ({ contractName }: ContractUIProps) => {
  const { targetNetwork } = useTargetNetwork();
  const { data: deployedContractData, isLoading: deployedContractLoading } = useDeployedContractInfo({ contractName });
  const isClonedContract = contractName === CLONED_CONTRACT_NAME;

  const { data: allCommissions } = useScaffoldReadContract({
    contractName: "CommissionEscrowFactory",
    functionName: "getAllCommissions",
    query: { enabled: isClonedContract },
  });
  const firstCommission = allCommissions?.[0];

  const [commissionAddress, setCommissionAddress] = useState("");

  useEffect(() => {
    if (isClonedContract && !commissionAddress && firstCommission) {
      setCommissionAddress(firstCommission);
    }
  }, [isClonedContract, commissionAddress, firstCommission]);

  if (deployedContractLoading) {
    return (
      <div className="mt-14">
        <span className="loading loading-spinner loading-lg"></span>
      </div>
    );
  }

  if (!deployedContractData) {
    return (
      <p className="text-3xl mt-14">
        No contract found by the name of {contractName} on chain {targetNetwork.name}!
      </p>
    );
  }

  const displayedAddress = (
    isClonedContract && commissionAddress ? commissionAddress : deployedContractData.address
  ) as Address;

  return (
    <div className="flex flex-col gap-4 w-full items-center">
      {isClonedContract && (
        <div className="w-full max-w-lg px-6 lg:px-10">
          <span className="text-sm font-bold">Commission address</span>
          <AddressInput
            value={commissionAddress}
            onChange={setCommissionAddress}
            placeholder="Enter a CommissionEscrow commission (clone) address"
          />
          <p className="text-xs mt-1 opacity-70">
            Defaults to the first commission created via <code>createCommission</code>. Paste any other commission
            address to inspect it instead.
          </p>
        </div>
      )}
      <Contract
        key={displayedAddress}
        contractName={contractName as string}
        contract={{ ...deployedContractData, address: displayedAddress }}
        chainId={targetNetwork.id}
      />
    </div>
  );
};
