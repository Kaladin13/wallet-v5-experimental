import "@acton/build"
import "@acton/crypto"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "../contracts/config"
import "../contracts/errors"
import "../contracts/messages"
import "../contracts/storage"
import "../wrappers/WalletV5.gen"
import "../wrappers/utils"

const TEST_WALLET_CODE_CONFIG_ID = 47

fun updateTestStorage(
    keyPair: KeyPair,
    seqno: uint32 = 0,
    codeVersion: uint8 = 0,
): Storage {
    return Storage {
        isSignatureAllowed: true,
        seqno,
        subwalletId: DEFAULT_SUBWALLET_ID,
        publicKey: keyPair.publicKey,
        extensions: [],
        wasKeyChanged: false,
        codeVersion,
    };
}

fun setWalletCodeConfig(codeVersion: uint8, code: cell): void {
    var approvedCodes: ConfigMap = [];
    approvedCodes.set(codeVersion, code);

    val configParam = beginCell().storeDict(approvedCodes.toLowLevelDict()).endCell();
    var config = testing.getConfig();
    config.setParamRaw(TEST_WALLET_CODE_CONFIG_ID, configParam);
    expect(testing.setConfig(config)).toBeTrue();
}

fun makeUpdateActions(previousData: cell, newData: cell, codeVersion: uint8): ActionsList {
    var extraActions: array<ExtraAction> = [];
    extraActions.push(UpdateContract {
        prevDataHash: previousData.hash(),
        newData,
        codeVersion,
    });
    return ActionsList {
        outActions: [],
        extraActions,
    };
}

fun WalletV5.getActiveStateInitForUpdateTest(self): StateInit {
    val account = testing.getAccountState(self.address);
    if (account == null) {
        Assert.fail("wallet account is missing");
    }
    val state = account.storage.state;
    match (state) {
        TlbAccountStateActive => return state.stateInit,
        TlbAccountStateUninit => Assert.fail("wallet account is uninitialized"),
        TlbAccountStateFrozen => Assert.fail("wallet account is frozen"),
    }
}

fun WalletV5.getStorageForUpdateTest(self): Storage {
    val stateInit = self.getActiveStateInitForUpdateTest();
    if (stateInit.data == null) {
        Assert.fail("wallet data is missing");
    }
    return Storage.fromCell(stateInit.data);
}

get fun `test w5 update: owner installs code approved by config param 47`() {
    val keyPair = crypto.generateKeyPair();
    val (walletV5, _) = deployWallet(updateTestStorage(keyPair));

    val approvedCode = build("WalletV5");
    setWalletCodeConfig(1, approvedCode);

    // External signed requests increment seqno before processing extra actions.
    val previousData = updateTestStorage(keyPair, 1, 0).toCell();
    val newData = updateTestStorage(keyPair, 1, 1).toCell();
    val body = createExternalSignedBody(
        keyPair,
        DEFAULT_SUBWALLET_ID,
        0,
        makeUpdateActions(previousData, newData, 1),
    );

    val receipt = walletV5.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: 0 });
    val stateInit = walletV5.getActiveStateInitForUpdateTest();
    expect(stateInit.code!.hash()).toEqual(approvedCode.hash());
    expect(stateInit.data!.hash()).toEqual(newData.hash());
    expect(walletV5.getStorageForUpdateTest().codeVersion).toEqual(1);
}

get fun `test w5 update: internal owner-signed request can update`() {
    val keyPair = crypto.generateKeyPair();
    val (walletV5, sender) = deployWallet(updateTestStorage(keyPair));
    val approvedCode = build("WalletV5");
    setWalletCodeConfig(1, approvedCode);

    val previousData = updateTestStorage(keyPair, 1, 0).toCell();
    val newData = updateTestStorage(keyPair, 1, 1).toCell();
    val body = createSignedBody(
        keyPair,
        DEFAULT_SUBWALLET_ID,
        0,
        makeUpdateActions(previousData, newData, 1),
    );

    val receipt = walletV5.sendSignedBody(sender.address, body, { value: ton("0.1") });

    expect(receipt).toHaveTx({ exitCode: 0 });
    expect(walletV5.getStorageForUpdateTest().codeVersion).toEqual(1);
    expect(walletV5.getActiveStateInitForUpdateTest().code!.hash()).toEqual(approvedCode.hash());
}

get fun `test w5 update: extension cannot update`() {
    val keyPair = crypto.generateKeyPair();
    val extension = testing.treasury("update-extension");
    var initialStorage = updateTestStorage(keyPair);
    val (_, extensionHash) = extension.address.getWorkchainAndHash();
    initialStorage.extensions.set(extensionHash, true);
    val (walletV5, _) = deployWallet(initialStorage);

    val previousData = initialStorage.toCell();
    var newStorage = initialStorage;
    newStorage.codeVersion = 1;
    val receipt = walletV5.sendExtensionActionBody(
        extension.address,
        makeUpdateActions(previousData, newStorage.toCell(), 1),
        0,
        { value: ton("0.1") },
    );

    expect(receipt).toHaveTx({ exitCode: Errors.OnlyOwnerCanChangeKey });
    expect(walletV5.getStorageForUpdateTest().codeVersion).toEqual(0);
}

get fun `test w5 update: stale previous data hash is rejected`() {
    val keyPair = crypto.generateKeyPair();
    val (walletV5, _) = deployWallet(updateTestStorage(keyPair));

    // seqno is already 1 by the time UpdateContract runs, so seqno 0 is stale.
    val staleData = updateTestStorage(keyPair, 0, 0).toCell();
    val newData = updateTestStorage(keyPair, 1, 1).toCell();
    val body = createExternalSignedBody(
        keyPair,
        DEFAULT_SUBWALLET_ID,
        0,
        makeUpdateActions(staleData, newData, 1),
    );

    val receipt = walletV5.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: Errors.PrevDataHashMismatch });
    expect(walletV5.getStorageForUpdateTest().codeVersion).toEqual(0);
}

get fun `test w5 update: code version must strictly increase`() {
    val keyPair = crypto.generateKeyPair();
    val (walletV5, _) = deployWallet(updateTestStorage(keyPair, 0, 1));

    val currentData = updateTestStorage(keyPair, 1, 1).toCell();
    val body = createExternalSignedBody(
        keyPair,
        DEFAULT_SUBWALLET_ID,
        0,
        makeUpdateActions(currentData, currentData, 1),
    );

    val receipt = walletV5.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: Errors.LowCodeVersion });
    expect(walletV5.getStorageForUpdateTest().codeVersion).toEqual(1);
}

get fun `test w5 update: missing config param 47 is rejected`() {
    val keyPair = crypto.generateKeyPair();
    val (walletV5, _) = deployWallet(updateTestStorage(keyPair));

    var config = testing.getConfig();
    config.delete(TEST_WALLET_CODE_CONFIG_ID);
    expect(testing.setConfig(config)).toBeTrue();

    val previousData = updateTestStorage(keyPair, 1, 0).toCell();
    val newData = updateTestStorage(keyPair, 1, 1).toCell();
    val body = createExternalSignedBody(
        keyPair,
        DEFAULT_SUBWALLET_ID,
        0,
        makeUpdateActions(previousData, newData, 1),
    );

    val receipt = walletV5.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: Errors.ConfigCodeCellEmpty });
    expect(walletV5.getStorageForUpdateTest().codeVersion).toEqual(0);
}

get fun `test w5 update: version absent from config map is rejected`() {
    val keyPair = crypto.generateKeyPair();
    val (walletV5, _) = deployWallet(updateTestStorage(keyPair));
    setWalletCodeConfig(2, build("WalletV5"));

    val previousData = updateTestStorage(keyPair, 1, 0).toCell();
    val newData = updateTestStorage(keyPair, 1, 1).toCell();
    val body = createExternalSignedBody(
        keyPair,
        DEFAULT_SUBWALLET_ID,
        0,
        makeUpdateActions(previousData, newData, 1),
    );

    val receipt = walletV5.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: Errors.ConfigCodeCellEmpty });
    expect(walletV5.getStorageForUpdateTest().codeVersion).toEqual(0);
}

get fun `test w5 update: new data may keep a lower code version`() {
    val keyPair = crypto.generateKeyPair();
    val (walletV5, _) = deployWallet(updateTestStorage(keyPair));
    setWalletCodeConfig(1, build("WalletV5"));

    val previousData = updateTestStorage(keyPair, 1, 0).toCell();
    val newData = updateTestStorage(keyPair, 1, 0).toCell();
    val body = createExternalSignedBody(
        keyPair,
        DEFAULT_SUBWALLET_ID,
        0,
        makeUpdateActions(previousData, newData, 1),
    );

    val receipt = walletV5.sendExternalSigned(body)!;

    expect(receipt).toHaveTx({ exitCode: 0 });
    expect(walletV5.getStorageForUpdateTest().codeVersion).toEqual(0);
}
