---
title: ".NET Background service with a queue"
date: 2023-09-26T15:00:00+02:00
draft: false
toc: false
images:
tags:
  - software
---
## The Problem
Recently at my job we had the next problem - in one of our apps we have a functionality to export some data in the form of Excel files. A user requests some kind of report, request is send to the .NET Web API, which then returns the generated report from the report service back in the form of a `FileStream`, which is then converted to a `.xlsx` file in the front end and downloaded to the user machine.

This piece of code shows how we handled report generation on the Controller level:
```C#
[HttpPost("Download")]
public async Task<IActionResult> DownloadFile([FromBody] DownloadReportRequest request)
{
    // generate .xlsx and convert into a stream
    var fileStream = await _reportsService.GenerateReport(request);

    // return the file
    return new FileStreamResult(fileStream, "application/ms-excel");
}
```

All was great and dandy until the users started requesting 'bigger' reports (in our case data from a larger timespan) which in the end prolonged the time which the report service needed to generate those reports. As a result, the browser refused to wait for so long (minutes) and timed-out the connection with the API. It was a bad design decision in the first place to keep the browser waiting for the response but now we had unhappy users on the other side not getting their reports. Something had to be done!

## The Solution
The solution was pretty straightforward - let's take the user request for the report, respond to the UI that the request was received so the user can continue doing other tasks in the app, generate the report in the background and send it via email to the user when it's finished!

To implement this idea I used `ConcurrentQueue<T>` collection for storing user requests which is then consumed by a service implementing the .NET `BackgroundService` base class for long running services.


### Implementing ConcurrentQueue
`ConcurrentQueue<T>` is a thread-safe first in-first out (FIFO) collection and it's an ideal collection for this use-case. For generating the report we need the `GenerateReportRequest` object containing all the needed data and the email of the user so the type of the queue collection will be a tuple containing those two values -> `ConcurrentQueue<(GenerateReportRequest, string)>`.

The clean way to use this collection is to encapsulate it and expose its `Enqueue` and `Dequeue` functionalities:
```C#
public interface IReportGenerationQueue
{
    void Enqueue(string email, GenerateReportRequest request);
    (string email, GenerateReportRequest? request) Dequeue();
}
```

```C#
public class ReportGenerationQueue : IReportGenerationQueue
{
    private readonly ConcurrentQueue<(string, GenerateReportRequest?)> _items = new();

    public void Enqueue(string email, GenerateReportRequest request)
    {
        if (request == null) throw new ArgumentNullException(nameof(request)); 
        if (string.IsNullOrWhiteSpace(email)) throw new ArgumentNullException("Report generation email");
        
        _items.Enqueue((email, request));
    }

    public (string, GenerateReportRequest?) Dequeue()
    {
        _items.TryDequeue(out var workItem);

        return workItem;
    }
}
```

To use this `ReportGenerationQueue` firstly we need to register it as a Singleton service:
`services.AddSingleton<IReportGenerationQueue, ReportGenerationQueue>();`

And then we can use it in the Controller to enqueue background jobs:
```C#
public class ReportsController : ControllerBase
{
    private readonly IReportGenerationQueue _queue;

    public ReportsController(IReportGenerationQueue queue)
    {
        _queue = queue;
    }

    [HttpPost("Generate")]
    public IActionResult GenerateFile([FromBody] GenerateReportRequest request)
    {
        // enqueue report generation with users email an the request
        _queue.Enqueue(User.Identity.Name, request);
        
        return NoContent();
    }
}
```

### What is a BackgroundService?
Next we need a worker which will run constantly and consume (dequeue) items from the `ConcurrentQueue<(GenerateReportRequest, string)>` collection.
`BackgroundService` is a base class which we inherit from to create long running tasks in our app. Each class that inherits from `BackgroundService` needs to implement (override) the `Task ExecuteAsync(CancellationToken)` method. This method is invoked at the start of our long running task. The idea is to use a `while` loop inside this method to create an always running loop until the cancellation is requested via the `CancellationToken`.

This is how it looks in practice:

```C#
public class ReportBackgroundWorker : BackgroundService
{
    private readonly IReportGenerationQueue _queue;
    private readonly IServiceScopeFactory _serviceScopeFactory;

    public ReportBackgroundWorker(
        IReportGenerationQueue queue,
        IServiceScopeFactory serviceScopeFactory)
    {
        _queue = queue;
        _serviceScopeFactory = serviceScopeFactory;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
			await DoWorkAsync();
        }
    }

    private async Task DoWorkAsync()
    {
        var workItem = _queue.Dequeue();

        if(workItem.request == null) continue;

        using(var scope = _serviceScopeFactory.CreateScope())
        {
            var reportsService = scope.ServiceProvider.GetRequiredService<IReportService>();
            var mailService = scope.ServiceProvider.GetRequiredService<IMailService>();

            var fileStream = await reportService.GenerateReport(workItem.request);

            await mailService.SendReport(fileStream, workItem.email);
        }
    }
}
```

In here, we're injecting `IReportGenerationQueue` which we use for fetching work items from the `ConcurrentQueue` collection using the `Dequeue` method, and `IServiceScopeFactory` which we use to create scoped services needed for our tasks. I won't go further into detail why we need to use this service scope factory approach, but I'll sure cover it in some other future blog post.

`ExecuteAsync` is invoked at the start of the background worker lifecycle and is 'stuck' in the `while` loop running the `DoWorkAsync()` method which does all the heavy lifting. In this method we check if there are any items in our queue, if not finish the execution of the `DoWorkAsync()` method. If we do have any items in our queue, then they're gonna be dequeued and processed, in this case, using the `ReportService` and the `MailService`. In the end, the user receives an email containing the requested report.

## Conclusion
This is a lightweight approach for implementing long running tasks with a queue. Another approach in doing this would be to use some other library such as [Hangfire](https://www.hangfire.io/) which comes with a dashboard UI but requires additional plumbing such as a SQL database.