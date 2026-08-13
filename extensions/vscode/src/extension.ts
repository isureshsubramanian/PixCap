import * as vscode from 'vscode';
import * as net from 'net';
import * as fs from 'fs';

const MACOS_SOCKET_PATH = '/tmp/pixcap.sock';
const WIN_PIPE_PATH = '\\\\.\\pipe\\pixcap';

export function activate(context: vscode.ExtensionContext) {
    console.log('PixCap VS Code Extension is active');

    const disposable = vscode.commands.registerCommand('pixcap.captureSelection', async () => {
        const editor = vscode.window.activeTextEditor;
        if (!editor) {
            vscode.window.showErrorMessage('PixCap: No active editor found');
            return;
        }

        const selection = editor.selection;
        const selectedCode = editor.document.getText(selection);
        if (!selectedCode) {
            vscode.window.showWarningMessage('PixCap: Please select code to beautify');
            return;
        }

        const languageId = editor.document.languageId;
        const ipcPath = process.platform === 'win32' ? WIN_PIPE_PATH : MACOS_SOCKET_PATH;

        const payload = {
            action: 'RenderSnippet',
            payload: {
                code: selectedCode,
                language: languageId,
                theme: 'base16-ocean.dark'
            }
        };

        try {
            const client = net.connect(ipcPath, () => {
                client.write(JSON.stringify(payload));
            });

            let responseData = '';
            client.on('data', (data) => {
                responseData += data.toString();
            });

            client.on('end', () => {
                try {
                    const response = JSON.parse(responseData);
                    if (response.status === 'Success' && response.data?.svg_content) {
                        vscode.env.clipboard.writeText(response.data.svg_content);
                        vscode.window.showInformationMessage('✨ PixCap: Beautified SVG code snippet copied to clipboard!');
                    } else {
                        vscode.window.showErrorMessage(`PixCap Error: ${response.data?.error_message || 'Render failed'}`);
                    }
                } catch (e: any) {
                    vscode.window.showErrorMessage(`PixCap JSON Error: ${e.message}`);
                }
            });

            client.on('error', (err) => {
                vscode.window.showWarningMessage(
                    `PixCap Core app is not running locally. (IPC path: ${ipcPath}). Launching default SVG generator...`
                );
            });
        } catch (err: any) {
            vscode.window.showErrorMessage(`PixCap IPC Connection Error: ${err.message}`);
        }
    });

    context.subscriptions.push(disposable);
}

export function deactivate() {}
