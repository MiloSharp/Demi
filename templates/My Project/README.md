# Demi 0.9.0-beta

Demi is a local, multi-agent collaboration room. This is a clean beta installation: it contains no credentials, chat history, manuscripts, or preconfigured AI agents.

## Start

Run Demi.cmd web for this computer, or Demi.cmd web lan for your home network. The default project is configured in %LOCALAPPDATA%\Demi\settings.json.

Open **People & Agents** to name the owner, add human profiles, and configure local, subscription-backed, HTTP API, or image agents. API keys are stored in the local credential store and are never part of the project template.

## Projects

The starter project is at Documents\Demi Projects\My Project. Copy the template or run 	ools\setup-demi.ps1 to create another project. Projects keep their own configuration, sessions, state, agents, canon, books, and inbox.

## Storage

File storage works without PostgreSQL. PostgreSQL is optional; the clean migrations are in database\migrations, and Demi can import an existing file-backed project after database setup.

## Requirements

Windows 11 and PowerShell 7 are recommended. A Node.js runtime is included in untime for this staged installation.

## Beta notice

Back up important projects before upgrades. This is version 0.9.0-beta and has not yet been through a signed installer or automatic-upgrade process.