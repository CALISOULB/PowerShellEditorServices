﻿// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System.Threading;
using System.Threading.Tasks;
using MediatR;
using Microsoft.Extensions.Logging;
using Microsoft.PowerShell.EditorServices.Extensions;

namespace Microsoft.PowerShell.EditorServices.Services.Extension
{
    internal class InvokeExtensionCommandHandler : IInvokeExtensionCommandHandler
    {
        private readonly ILogger<InvokeExtensionCommandHandler> _logger;
        private readonly ExtensionService _extensionService;
        private readonly EditorOperationsService _editorOperationsService;

        public InvokeExtensionCommandHandler(
            ILoggerFactory factory,
            ExtensionService extensionService,
            EditorOperationsService editorOperationsService
            )
        {
            _logger = factory.CreateLogger<InvokeExtensionCommandHandler>();
            _extensionService = extensionService;
            _editorOperationsService = editorOperationsService;
        }

        public async Task<Unit> Handle(InvokeExtensionCommandParams request, CancellationToken cancellationToken)
        {
            // We can now await here because we handle asynchronous message handling.
            EditorContext editorContext =
                _editorOperationsService.ConvertClientEditorContext(
                    request.Context);

            await _extensionService.InvokeCommandAsync(
                request.Name,
                editorContext).ConfigureAwait(false);

            return await Unit.Task.ConfigureAwait(false);
        }
    }
}
